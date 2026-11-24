mod online;
mod playback;
mod web;

use std::env;
use std::fs::File;
use std::io::{self, Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::Serialize;
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

use online::OnlineCatalog;
use playback::{Playback, Reply};
use web::WebLibrary;

const VERSION: &str = "Kontur desktop bridge 11";
const IDLE: Duration = Duration::from_secs(15 * 60);
const WORKERS: usize = 6;

struct App {
    root: PathBuf,
    host: String,
    origin: String,
    playback: Playback,
    web: WebLibrary,
    online: OnlineCatalog,
    last_use: Mutex<Instant>,
}

type HttpResponse = Response<Box<dyn Read + Send>>;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let root = env::current_exe()?
        .parent()
        .ok_or_else(|| io::Error::other("Cannot resolve the Kontur directory"))?
        .to_path_buf();
    let port = env::var("KONTUR_PORT").map_or(Ok(48371), |value| value.parse::<u16>())?;
    let host = format!("127.0.0.1:{port}");
    let origin = format!("http://{host}");
    let validate_only = env::var_os("KONTUR_VALIDATE_ONLY").is_some_and(|value| value == "1");
    let server = Arc::new(Server::http(&host)?);
    let app = Arc::new(App {
        playback: Playback::new(&root, &origin, validate_only),
        web: WebLibrary::new(&root),
        online: OnlineCatalog::new(),
        root,
        host,
        origin,
        last_use: Mutex::new(Instant::now()),
    });
    let starting = Arc::clone(&app);
    thread::spawn(move || starting.playback.restore());
    for _ in 0..WORKERS {
        let app = Arc::clone(&app);
        let server = Arc::clone(&server);
        thread::spawn(move || {
            while let Ok(request) = server.recv() {
                app.serve(request);
            }
        });
    }
    loop {
        thread::sleep(Duration::from_secs(5));
        let inactive = app.last_use.lock().is_ok_and(|time| time.elapsed() > IDLE);
        if inactive && !app.playback.is_active() {
            return Ok(());
        }
    }
}

impl App {
    fn serve(&self, mut request: Request) {
        let response = if header(&request, "Host") == Some(&self.host) {
            if let Ok(mut time) = self.last_use.lock() {
                *time = Instant::now();
            }
            self.route(&mut request)
        } else {
            plain(403, "")
        };
        if let Err(error) = request.respond(response)
            && error.kind() != io::ErrorKind::BrokenPipe
        {
            eprintln!("{error}");
        }
    }

    fn route(&self, request: &mut Request) -> HttpResponse {
        let url = request.url().to_owned();
        if request.method() == &Method::Get {
            return self.get(request, &url);
        }
        if request.method() == &Method::Post {
            return self.post(request, &url);
        }
        plain(404, "")
    }

    fn get(&self, request: &Request, url: &str) -> HttpResponse {
        match url {
            "/status" => plain(200, VERSION),
            "/video-status" => plain(200, self.playback.status()),
            "/web-list" => json(&self.web.list()),
            path if path.starts_with("/web-preview/") => {
                match self.web.preview(&path["/web-preview/".len()..]) {
                    Ok((data, mime)) => bytes(200, mime, data),
                    Err(_) => plain(404, ""),
                }
            }
            path if path.starts_with("/online/") => self.get_online(request, path),
            path => static_file(&self.root, path).unwrap_or_else(|| plain(404, "")),
        }
    }

    fn get_online(&self, request: &Request, url: &str) -> HttpResponse {
        let (path, query) = url.split_once('?').unwrap_or((url, ""));
        let thumb = path.strip_prefix("/online/thumb/");
        if header(request, "Origin").is_some_and(|value| value != self.origin)
            || (thumb.is_none() && header(request, "X-Kontur-Action") != Some("online"))
        {
            return plain(403, "");
        }
        if path == "/online/search" {
            return match self.online.search(query) {
                Ok(results) => json(&results),
                Err(error) => plain(error.status, &error.message),
            };
        }
        let Some(id) = thumb.or_else(|| path.strip_prefix("/online/file/")) else {
            return plain(404, "");
        };
        if !managed_id(id) {
            return plain(404, "");
        }
        match self.online.media(id, thumb.is_some()) {
            Ok(media) => response(200, &media.mime, media.body, media.length),
            Err(error) => plain(error.status, &error.message),
        }
    }

    fn post(&self, request: &mut Request, path: &str) -> HttpResponse {
        let action = match path {
            "/web-import" | "/web-wallpaper" | "/web-options" => "set-web",
            "/video-wallpaper" | "/stop-video" => "set-video",
            "/wallpaper" => "set-wallpaper",
            _ => return plain(404, ""),
        };
        if header(request, "Origin") != Some(&self.origin)
            || header(request, "X-Kontur-Action") != Some(action)
        {
            return plain(403, "");
        }
        let length = request.body_length().map(|length| length as u64);
        let id = header(request, "X-Kontur-Project");
        let fps = header(request, "X-Kontur-Fps");
        let reply = match path {
            "/web-import" => {
                let format = header(request, "X-Kontur-Format")
                    .unwrap_or("rar")
                    .to_owned();
                return match self.web.import(request.as_reader(), length, &format) {
                    Ok(project) => json(&project),
                    Err(message) => plain(400, &message),
                };
            }
            "/web-wallpaper" => self.playback.start_web(&self.web, id, fps),
            "/web-options" => self.playback.web_fps(id, fps),
            "/stop-video" => self.playback.stop(),
            "/video-wallpaper" => {
                let mime = match header(request, "Content-Type") {
                    Some("video/mp4") => "video/mp4",
                    Some("video/webm") => "video/webm",
                    _ => return plain(415, ""),
                };
                self.playback.start_video(request.as_reader(), length, mime)
            }
            _ if header(request, "Content-Type") == Some("image/png") => {
                self.playback.photo(request.as_reader(), length)
            }
            _ => return plain(403, ""),
        };
        let Reply { status, body } = reply;
        plain(status, body)
    }
}

fn header<'a>(request: &'a Request, name: &'static str) -> Option<&'a str> {
    request
        .headers()
        .iter()
        .find(|header| header.field.equiv(name))
        .map(|header| header.value.as_str())
}

fn managed_id(value: &str) -> bool {
    value.len() == 36
        && value
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f' | b'-'))
}

fn static_file(root: &Path, path: &str) -> Option<HttpResponse> {
    let (directory, filename) = path.strip_prefix('/')?.split_once('/')?;
    let (stem, extension) = filename.split_once('.')?;
    if !matches!(directory, "ui" | "assets")
        || stem.is_empty()
        || !stem
            .bytes()
            .all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'-'))
    {
        return None;
    }
    let mime = match extension {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" => "text/javascript; charset=utf-8",
        "png" => "image/png",
        "jpg" => "image/jpeg",
        "wav" => "audio/wav",
        _ => return None,
    };
    let file = File::open(root.join(directory).join(filename)).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    Some(response(
        200,
        mime,
        Box::new(file),
        Some(metadata.len() as usize),
    ))
}

fn response(
    status: u16,
    mime: &str,
    body: Box<dyn Read + Send>,
    len: Option<usize>,
) -> HttpResponse {
    let headers = [
        ("Content-Type", mime),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
    ]
    .into_iter()
    .filter_map(|(name, value)| Header::from_bytes(name, value).ok())
    .collect();
    Response::new(StatusCode(status), headers, body, len, None)
}

fn bytes(status: u16, mime: &str, data: Vec<u8>) -> HttpResponse {
    let length = data.len();
    response(status, mime, Box::new(Cursor::new(data)), Some(length))
}

fn plain(status: u16, message: &str) -> HttpResponse {
    bytes(
        status,
        "text/plain; charset=utf-8",
        message.as_bytes().to_vec(),
    )
}

fn json(value: &impl Serialize) -> HttpResponse {
    match serde_json::to_vec(value) {
        Ok(data) => bytes(200, "application/json; charset=utf-8", data),
        Err(error) => {
            eprintln!("{error}");
            plain(500, "")
        }
    }
}
