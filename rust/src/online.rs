use serde::Serialize;
use serde_json::Value;
use std::collections::VecDeque;
use std::io::Read;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use ureq::http::header::{ACCEPT, CONTENT_LENGTH, CONTENT_TYPE, LOCATION};
use ureq::tls::{RootCerts, TlsConfig, TlsProvider};
use ureq::{Agent, Body, http::Response};
use url::Url;
use uuid::Uuid;

const USER_AGENT: &str = "KonturWallpaper/0.2 (https://github.com/DavM1x)";
const DOWNLOAD_LIMIT: u64 = 128 * 1024 * 1024;
const THUMB_LIMIT: u64 = 4 * 1024 * 1024;
const SEARCH_LIMIT: u64 = 2 * 1024 * 1024;
const SEARCH_TIMEOUT: Duration = Duration::from_secs(20);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(90);
const CACHE_TIME: Duration = Duration::from_secs(20 * 60);
const CACHE_LIMIT: usize = 384;
const COMMONS_PAGE_SIZE: usize = 16;
const FLICKR_PAGE_SIZE: usize = 8;
const MAX_OFFSET: usize = COMMONS_PAGE_SIZE * 12;

type Result<T> = std::result::Result<T, CatalogError>;

#[derive(Debug)]
pub struct CatalogError {
    pub status: u16,
    pub message: String,
}

impl CatalogError {
    fn new(status: u16, message: &str) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }

    fn unavailable() -> Self {
        Self::new(
            502,
            "Не удалось связаться с источником. Проверь интернет и повтори запрос.",
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Provider {
    Commons,
    Flickr,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Kind {
    Image,
    Video,
}

struct MediaFormat {
    kind: Kind,
    mime: &'static str,
    extension: &'static str,
}

const MEDIA_FORMATS: [MediaFormat; 5] = [
    MediaFormat {
        kind: Kind::Image,
        mime: "image/jpeg",
        extension: "jpg",
    },
    MediaFormat {
        kind: Kind::Image,
        mime: "image/png",
        extension: "png",
    },
    MediaFormat {
        kind: Kind::Image,
        mime: "image/webp",
        extension: "webp",
    },
    MediaFormat {
        kind: Kind::Video,
        mime: "video/webm",
        extension: "webm",
    },
    MediaFormat {
        kind: Kind::Video,
        mime: "video/mp4",
        extension: "mp4",
    },
];

fn by_mime(mime: &str) -> Option<&'static MediaFormat> {
    MEDIA_FORMATS.iter().find(|format| format.mime == mime)
}

#[derive(Serialize)]
struct License {
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
}

#[derive(Serialize)]
struct SearchItem {
    id: String,
    key: String,
    title: String,
    author: String,
    page: String,
    rights: License,
    kind: Kind,
    mime: &'static str,
    extension: &'static str,
    width: u64,
    height: u64,
    preview: bool,
}

#[derive(Serialize)]
pub struct SearchResults {
    results: Vec<SearchItem>,
    next: Option<usize>,
}

struct SavedMedia {
    id: String,
    provider: Provider,
    original: Url,
    thumbnail: Option<Url>,
    mime: &'static str,
    expires: Instant,
}

type SearchEntry = (SearchItem, SavedMedia);
type SearchPage = (Vec<SearchEntry>, Option<usize>);

pub struct Media {
    pub mime: String,
    pub body: Box<dyn Read + Send>,
    pub length: Option<usize>,
}

pub struct OnlineCatalog {
    agent: Agent,
    saved: Mutex<VecDeque<SavedMedia>>,
}

impl OnlineCatalog {
    pub fn new() -> Self {
        let agent = Agent::config_builder()
            .https_only(true)
            .max_redirects(0)
            .http_status_as_error(false)
            .user_agent(USER_AGENT)
            .tls_config(
                TlsConfig::builder()
                    .provider(TlsProvider::NativeTls)
                    .root_certs(RootCerts::PlatformVerifier)
                    .build(),
            )
            .build()
            .into();
        Self {
            agent,
            saved: Mutex::default(),
        }
    }

    pub fn search(&self, query: &str) -> Result<SearchResults> {
        let query = url::form_urlencoded::parse(query.trim_start_matches('?').as_bytes())
            .collect::<Vec<_>>();
        let param = |name| {
            query
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.as_ref())
                .unwrap_or("")
        };
        let invalid = || CatalogError::new(400, "Проверь запрос и выбранный источник.");
        let provider = match param("source") {
            "commons" => Provider::Commons,
            "flickr" => Provider::Flickr,
            _ => return Err(invalid()),
        };
        let kind = match param("kind") {
            "image" => Kind::Image,
            "video" if provider == Provider::Commons => Kind::Video,
            _ => return Err(invalid()),
        };
        let query = param("q").trim();
        let offset = match param("offset").trim() {
            "" => 0,
            offset => offset.parse::<usize>().map_err(|_| invalid())?,
        };
        if !(2..=100).contains(&query.encode_utf16().count()) || offset > MAX_OFFSET {
            return Err(invalid());
        }

        let now = Instant::now();
        let expires = now + CACHE_TIME;
        let (items, next) = match provider {
            Provider::Commons => self.commons(query, kind, offset, expires)?,
            Provider::Flickr => self.flickr(query, offset, expires)?,
        };
        let mut saved = self.saved.lock().map_err(|_| CatalogError::unavailable())?;
        saved.retain(|item| item.expires > now);
        let results = items
            .into_iter()
            .map(|(item, media)| {
                saved.push_back(media);
                item
            })
            .collect();
        let extra = saved.len().saturating_sub(CACHE_LIMIT);
        saved.drain(..extra);
        Ok(SearchResults {
            results,
            next: next.filter(|&next| next > offset && next <= MAX_OFFSET),
        })
    }

    pub fn media(&self, id: &str, thumb: bool) -> Result<Media> {
        let unavailable = || CatalogError::new(404, "Результат недоступен. Повтори поиск.");
        let (provider, url, original_mime, fallback) = {
            let saved = self.saved.lock().map_err(|_| CatalogError::unavailable())?;
            let item = saved
                .iter()
                .find(|item| item.id == id && item.expires > Instant::now())
                .ok_or_else(unavailable)?;
            let url = if thumb {
                item.thumbnail.as_ref().ok_or_else(unavailable)?
            } else {
                &item.original
            };
            let fallback = (thumb && item.provider == Provider::Flickr && url != &item.original)
                .then(|| item.original.clone());
            (item.provider, url.clone(), item.mime, fallback)
        };
        let now = Instant::now();
        let deadline = now
            + if thumb {
                SEARCH_TIMEOUT
            } else {
                DOWNLOAD_TIMEOUT
            };
        let first_deadline = if fallback.is_some() {
            now + Duration::from_secs(5)
        } else {
            deadline
        };
        let response = self
            .open_media(url, provider, thumb, first_deadline)
            .or_else(|error| match fallback {
                Some(url) => self.open_media(url, provider, true, deadline),
                None => Err(error),
            })?;
        let limit = if thumb { THUMB_LIMIT } else { DOWNLOAD_LIMIT };
        let length = response
            .headers()
            .get(CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok());
        let mime = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .unwrap_or("");
        let allowed = if thumb {
            by_mime(mime).is_some_and(|format| format.kind == Kind::Image)
        } else {
            mime == original_mime
        };
        if !allowed || length.is_some_and(|length| length > limit) {
            return Err(CatalogError::new(
                415,
                "Источник отдал неподдерживаемый формат или слишком большой файл.",
            ));
        }
        Ok(Media {
            mime: mime.to_owned(),
            length: length.and_then(|length| usize::try_from(length).ok()),
            body: Box::new(
                response
                    .into_body()
                    .into_with_config()
                    .limit(limit)
                    .reader(),
            ),
        })
    }

    fn fetch(&self, url: &Url, accept: &str, deadline: Instant) -> Result<Response<Body>> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(CatalogError::unavailable());
        }
        self.agent
            .get(url.as_str())
            .header(ACCEPT, accept)
            .config()
            .timeout_global(Some(remaining))
            .build()
            .call()
            .map_err(|_| CatalogError::unavailable())
    }

    fn search_api(&self, url: &Url) -> Result<Value> {
        let response = self.fetch(url, "application/json", Instant::now() + SEARCH_TIMEOUT)?;
        if response.status().as_u16() == 429 {
            return Err(CatalogError::new(
                429,
                "Источник ограничил частоту запросов. Попробуй немного позже.",
            ));
        }
        if !response.status().is_success() {
            return Err(CatalogError::new(
                502,
                "Источник временно недоступен. Попробуй ещё раз или выбери другой.",
            ));
        }
        let body = response
            .into_body()
            .into_with_config()
            .limit(SEARCH_LIMIT)
            .reader();
        serde_json::from_reader(body).map_err(|_| CatalogError::unavailable())
    }

    fn commons(
        &self,
        query: &str,
        kind: Kind,
        offset: usize,
        expires: Instant,
    ) -> Result<SearchPage> {
        let mut url = Url::parse("https://commons.wikimedia.org/w/api.php")
            .map_err(|_| CatalogError::unavailable())?;
        let filters = if kind == Kind::Video {
            " filetype:video"
        } else {
            " filetype:bitmap filew:>959"
        };
        url.query_pairs_mut().extend_pairs([
            ("action", "query"),
            ("format", "json"),
            ("formatversion", "2"),
            ("generator", "search"),
            ("gsrnamespace", "6"),
            ("gsrlimit", &COMMONS_PAGE_SIZE.to_string()),
            ("gsroffset", &offset.to_string()),
            ("gsrsearch", &format!("{query}{filters}")),
            ("prop", "imageinfo"),
            ("iiprop", "url|size|mime|extmetadata"),
            ("iiurlwidth", "640"),
            ("iiextmetadatafilter", "Artist|LicenseShortName|LicenseUrl"),
        ]);
        let data = self.search_api(&url)?;
        if data.get("error").is_some() {
            return Err(CatalogError::new(
                502,
                "Wikimedia Commons не смог обработать поиск.",
            ));
        }
        let mut pages = data["query"]["pages"]
            .as_array()
            .into_iter()
            .flatten()
            .collect::<Vec<_>>();
        pages.sort_by_key(|page| page["index"].as_u64().unwrap_or(u64::MAX));
        let items = pages
            .into_iter()
            .filter_map(|page| {
                let info = page["imageinfo"].get(0)?;
                let metadata = &info["extmetadata"];
                let entry_title = page["title"].as_str()?;
                let entry_title = entry_title.strip_prefix("File:").unwrap_or(entry_title);
                let entry_title = entry_title
                    .rsplit_once('.')
                    .map_or(entry_title, |(title, _)| title);
                let page_url = https_url(string(&info["descriptionurl"]))?;
                if page_url.host_str() != Some("commons.wikimedia.org") {
                    return None;
                }
                Candidate {
                    provider: Provider::Commons,
                    key: format!("commons:{}", page["pageid"].as_u64()?),
                    title: clean_text(entry_title, 160),
                    author: clean_text(string(&metadata["Artist"]["value"]), 160),
                    page: page_url,
                    rights: license(
                        string(&metadata["LicenseShortName"]["value"]),
                        string(&metadata["LicenseUrl"]["value"]),
                    )?,
                    mime: string(&info["mime"]),
                    url: string(&info["url"]),
                    thumbnail: string(&info["thumburl"]),
                    width: number(&info["width"]),
                    height: number(&info["height"]),
                    size: number(&info["size"]),
                    kind,
                }
                .collect(expires)
            })
            .collect();
        let next = data["continue"]["gsroffset"]
            .as_u64()
            .and_then(|value| usize::try_from(value).ok());
        Ok((items, next))
    }

    fn flickr(&self, query: &str, offset: usize, expires: Instant) -> Result<SearchPage> {
        let mut url = Url::parse("https://api.openverse.org/v1/images/")
            .map_err(|_| CatalogError::unavailable())?;
        let page = offset / FLICKR_PAGE_SIZE + 1;
        let mut pairs = url::form_urlencoded::Serializer::new(String::new());
        pairs.extend_pairs([
            ("q", query),
            ("source", "flickr"),
            ("license", "cc0,pdm,by,by-sa"),
            ("page_size", &FLICKR_PAGE_SIZE.to_string()),
        ]);
        if page > 1 {
            pairs.append_pair("page", &page.to_string());
        }
        url.set_query(Some(&pairs.finish().replace('+', "%20")));
        let data = self.search_api(&url)?;
        let items = data["results"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|photo| flickr_item(photo, expires))
            .collect();
        let next =
            ((page as u64) < number(&data["page_count"])).then_some(offset + FLICKR_PAGE_SIZE);
        Ok((items, next))
    }

    fn open_media(
        &self,
        mut url: Url,
        provider: Provider,
        thumb: bool,
        deadline: Instant,
    ) -> Result<Response<Body>> {
        for _ in 0..4 {
            if !asset_allowed(provider, thumb, &url) {
                break;
            }
            let response = self.fetch(&url, "image/*,video/*", deadline)?;
            if response.status().is_redirection() {
                let redirected = response
                    .headers()
                    .get(LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| url.join(value).ok())
                    .filter(safe_https);
                let Some(next) = redirected else { break };
                url = next;
            } else if response.status().is_success() {
                return Ok(response);
            } else {
                break;
            }
        }
        Err(CatalogError::new(
            502,
            "Сайт не отдал файл. Открой оригинал или выбери другие обои.",
        ))
    }
}

struct Candidate<'a> {
    provider: Provider,
    key: String,
    title: String,
    author: String,
    page: Url,
    rights: License,
    mime: &'a str,
    url: &'a str,
    thumbnail: &'a str,
    width: u64,
    height: u64,
    size: u64,
    kind: Kind,
}

impl Candidate<'_> {
    fn collect(self, expires: Instant) -> Option<SearchEntry> {
        let format = by_mime(self.mime)?;
        if format.kind != self.kind
            || self.title.is_empty()
            || self.size > DOWNLOAD_LIMIT
            || (self.kind == Kind::Image
                && (self.width < 960 || self.height < 540 || self.width < self.height))
        {
            return None;
        }
        let original =
            https_url(self.url).filter(|url| asset_allowed(self.provider, false, url))?;
        let thumbnail =
            https_url(self.thumbnail).filter(|url| asset_allowed(self.provider, true, url));
        let id = Uuid::new_v4().hyphenated().to_string();
        Some((
            SearchItem {
                id: id.clone(),
                key: self.key,
                title: self.title,
                author: self.author,
                page: self.page.into(),
                rights: self.rights,
                kind: self.kind,
                mime: format.mime,
                extension: format.extension,
                width: self.width,
                height: self.height,
                preview: thumbnail.is_some(),
            },
            SavedMedia {
                id,
                provider: self.provider,
                original,
                thumbnail,
                mime: format.mime,
                expires,
            },
        ))
    }
}

fn flickr_item(photo: &Value, expires: Instant) -> Option<SearchEntry> {
    if photo["source"].as_str() != Some("flickr") {
        return None;
    }
    let page_url = https_url(string(&photo["foreign_landing_url"]))?;
    if !matches!(page_url.host_str(), Some("www.flickr.com" | "flickr.com")) {
        return None;
    }
    let version = string(&photo["license_version"]);
    let label = match photo["license"].as_str()? {
        "cc0" => "CC0".to_owned(),
        "pdm" => "Public domain".to_owned(),
        "by" => format!("CC BY {version}"),
        "by-sa" => format!("CC BY-SA {version}"),
        _ => return None,
    };
    let url = string(&photo["url"]);
    let extension = url
        .split('?')
        .next()?
        .rsplit_once('.')?
        .1
        .to_ascii_lowercase();
    let mime = match extension.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        _ => return None,
    };
    let title = clean_text(string(&photo["title"]), 160);
    Candidate {
        provider: Provider::Flickr,
        key: format!("flickr:{}", photo["id"].as_str()?),
        title: if title.is_empty() {
            "Фото Flickr".into()
        } else {
            title
        },
        author: clean_text(string(&photo["creator"]), 160),
        page: page_url,
        rights: license(&label, string(&photo["license_url"]))?,
        mime,
        url,
        thumbnail: string(&photo["thumbnail"]),
        width: number(&photo["width"]),
        height: number(&photo["height"]),
        size: number(&photo["filesize"]),
        kind: Kind::Image,
    }
    .collect(expires)
}

fn string(value: &Value) -> &str {
    value.as_str().unwrap_or("")
}

fn number(value: &Value) -> u64 {
    value
        .as_u64()
        .or_else(|| value.as_str()?.parse().ok())
        .unwrap_or(0)
}

fn safe_https(url: &Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
}

fn https_url(value: &str) -> Option<Url> {
    Url::parse(value).ok().filter(safe_https)
}

fn asset_allowed(provider: Provider, thumb: bool, url: &Url) -> bool {
    match (provider, url.host_str()) {
        (Provider::Commons, Some("upload.wikimedia.org")) => {
            url.path().starts_with("/wikipedia/commons/")
        }
        (Provider::Commons, Some("thumb.wikimedia.org")) => {
            thumb && url.path().starts_with("/wikipedia/commons/")
        }
        (Provider::Flickr, Some("live.staticflickr.com")) => true,
        (Provider::Flickr, Some("api.openverse.org")) => {
            thumb
                && url
                    .path()
                    .strip_prefix("/v1/images/")
                    .and_then(|path| path.strip_suffix("/thumb/"))
                    .is_some_and(|id| id.len() == 36 && Uuid::parse_str(id).is_ok())
        }
        (Provider::Flickr, Some(host)) => host
            .strip_prefix("farm")
            .and_then(|host| host.strip_suffix(".staticflickr.com"))
            .is_some_and(|number| {
                !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())
            }),
        _ => false,
    }
}

fn license(name: &str, link: &str) -> Option<License> {
    let label = clean_text(name, 40);
    let lower = label.to_ascii_lowercase();
    let recognized = matches!(
        lower.as_str(),
        "cc0" | "cc0 1.0" | "public domain" | "public domain mark"
    ) || lower
        .strip_prefix("cc by-sa ")
        .or_else(|| lower.strip_prefix("cc by "))
        .is_some_and(|version| {
            let bytes = version.as_bytes();
            matches!(bytes, [b'1'..=b'4', b'.', b'0' | b'5'])
        });
    if !recognized {
        return None;
    }
    let url = https_url(link)
        .filter(|url| {
            url.host_str() == Some("creativecommons.org")
                && [
                    "/licenses/by/",
                    "/licenses/by-sa/",
                    "/publicdomain/zero/",
                    "/publicdomain/mark/",
                ]
                .iter()
                .any(|prefix| url.path().starts_with(prefix))
        })
        .map(String::from);
    Some(License { label, url })
}

fn clean_text(mut input: &str, limit: usize) -> String {
    let mut output = String::new();
    let mut utf16_len = 0;
    let mut space = false;
    while let Some(mut ch) = input.chars().next() {
        input = &input[ch.len_utf8()..];
        if ch == '<' {
            if let Some(end) = input.find('>') {
                input = &input[end + 1..];
                ch = ' ';
            }
        } else if ch == '&' {
            for (entity, decoded) in [
                ("amp;", '&'),
                ("quot;", '"'),
                ("#39;", '\''),
                ("lt;", '<'),
                ("gt;", '>'),
                ("nbsp;", ' '),
            ] {
                if let Some(rest) = input.strip_prefix(entity) {
                    input = rest;
                    ch = decoded;
                    break;
                }
            }
        }
        if ch.is_whitespace() || ch <= '\u{001f}' || ch == '\u{feff}' {
            space = !output.is_empty();
            continue;
        }
        if utf16_len + usize::from(space) + ch.len_utf16() > limit {
            break;
        }
        if space {
            output.push(' ');
            utf16_len += 1;
            space = false;
        }
        output.push(ch);
        utf16_len += ch.len_utf16();
    }
    output
}
