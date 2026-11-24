import { randomUUID } from 'node:crypto';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const mediaTypes = new Map([
  ['image/jpeg', ['image', 'jpg']], ['image/png', ['image', 'png']], ['image/webp', ['image', 'webp']],
  ['video/webm', ['video', 'webm']], ['video/mp4', ['video', 'mp4']],
]);
const client = 'KonturWallpaper/0.2 (https://github.com/DavM1x)';
const maxDownload = 128 * 1024 * 1024;
const maxThumbnail = 4 * 1024 * 1024;
const pageSize = 16;
const flickrPageSize = 8;
const maxOffset = pageSize * 12;
const keyPattern = /^[a-f0-9-]{36}$/;

class CatalogError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function text(value, limit = 160) {
  const entities = {'&amp;':'&','&quot;':'"','&#39;':"'",'&lt;':'<','&gt;':'>','&nbsp;':' '};
  return String(value ?? '').replace(/<[^>]*>/g,' ').replace(/&(?:amp|quot|#39|lt|gt|nbsp);/g, entity => entities[entity])
    .replace(/[\s\u0000-\u001f]+/g,' ').trim().slice(0,limit);
}

function httpsUrl(value, allowed) {
  if (typeof value !== 'string') return undefined;
  try {
    const url = new URL(value);
    if (url.protocol === 'https:' && !url.username && !url.password && !url.port && allowed(url)) return url;
  } catch {}
}

function assetAllowed(provider, thumb, url) {
  if (provider === 'commons') {
    const wikimedia = url.hostname === 'upload.wikimedia.org' || (thumb && url.hostname === 'thumb.wikimedia.org');
    return wikimedia && url.pathname.startsWith('/wikipedia/commons/');
  }
  if (url.hostname === 'live.staticflickr.com' || /^farm[0-9]+\.staticflickr\.com$/.test(url.hostname)) return true;
  return thumb && url.hostname === 'api.openverse.org' && /^\/v1\/images\/[a-f0-9-]{36}\/thumb\/$/.test(url.pathname);
}

function license(name, value) {
  const label = text(name,40);
  const allowed = /^(?:CC0(?: 1\.0)?|public domain(?: mark)?|CC BY(?:-SA)? [1-4]\.[05])$/i;
  if (!allowed.test(label)) return undefined;
  const url = httpsUrl(value, link => link.hostname === 'creativecommons.org' && /^\/(?:licenses\/(?:by|by-sa)\/|publicdomain\/(?:zero|mark)\/)/.test(link.pathname));
  return {label, url:url?.href};
}

function item({provider, key, title, author, page, rights, mime, url, thumb, width, height, size, kind}) {
  const format = mediaTypes.get(mime);
  const original = httpsUrl(url, link => assetAllowed(provider,false,link));
  if (!format || format[0] !== kind || !title || !rights || !page || !original || size > maxDownload) return undefined;
  if (kind === 'image' && (width < 960 || height < 540 || width < height)) return undefined;
  const preview = httpsUrl(thumb, link => assetAllowed(provider,true,link));
  return {
    key:provider + ':' + key, title, author, rights, page, kind, mime, extension:format[1],
    width:Number(width) || 0, height:Number(height) || 0, url:original, thumb:preview,
  };
}

export function createOnlineCatalog(fetchOnline = fetch) {
  const resultsById = new Map();

  async function searchApi(url, signal) {
    const response = await fetchOnline(url, {headers:{'User-Agent':client, Accept:'application/json'}, redirect:'error', signal});
    if (response.status === 429) throw new CatalogError(429,'Источник ограничил частоту запросов. Попробуй немного позже.');
    if (!response.ok) throw new CatalogError(502,'Источник временно недоступен. Попробуй ещё раз или выбери другой.');
    return response.json();
  }

  async function commons(query, kind, offset, signal) {
    const url = new URL('https://commons.wikimedia.org/w/api.php');
    url.search = new URLSearchParams({
      action:'query', format:'json', formatversion:'2', generator:'search', gsrnamespace:'6',
      gsrlimit:String(pageSize), gsroffset:String(offset), gsrsearch:query + (kind === 'video' ? ' filetype:video' : ' filetype:bitmap filew:>959'),
      prop:'imageinfo', iiprop:'url|size|mime|extmetadata', iiurlwidth:'640',
      iiextmetadatafilter:'Artist|LicenseShortName|LicenseUrl',
    });
    const data = await searchApi(url, signal);
    if (data.error) throw new CatalogError(502,'Wikimedia Commons не смог обработать поиск.');
    const pages = data.query?.pages ?? [];
    const items = pages.sort((a,b) => a.index - b.index).map(page => {
      const info = page.imageinfo?.[0];
      if (!info) return undefined;
      const metadata = info.extmetadata ?? {};
      return item({provider:'commons', key:page.pageid, title:text(page.title?.replace(/^File:|\.[^.]+$/g,'')),
        author:text(metadata.Artist?.value), rights:license(metadata.LicenseShortName?.value,metadata.LicenseUrl?.value),
        page:httpsUrl(info.descriptionurl,link => link.hostname === 'commons.wikimedia.org')?.href,
        mime:info.mime, url:info.url, thumb:info.thumburl, width:info.width, height:info.height, size:info.size, kind});
    });
    return {items, next:data.continue?.gsroffset};
  }

  async function flickr(query, offset, signal) {
    const url = new URL('https://api.openverse.org/v1/images/');
    const page = Math.floor(offset / flickrPageSize) + 1;
    const params = new URLSearchParams({q:query, source:'flickr', license:'cc0,pdm,by,by-sa', page_size:String(flickrPageSize)});
    if (page > 1) params.set('page',String(page));
    url.search = params.toString().replaceAll('+','%20');
    const data = await searchApi(url, signal);
    const items = (data.results ?? []).map(photo => {
      if (photo.source !== 'flickr') return undefined;
      const label = {cc0:'CC0',pdm:'Public domain',by:'CC BY ' + photo.license_version,'by-sa':'CC BY-SA ' + photo.license_version}[photo.license];
      const format = /\.(jpe?g|png|webp)(?:\?|$)/i.exec(photo.url ?? '')?.[1]?.toLowerCase();
      const mime = {jpg:'image/jpeg',jpeg:'image/jpeg',png:'image/png',webp:'image/webp'}[format];
      return item({provider:'flickr', key:photo.id, title:text(photo.title) || 'Фото Flickr', author:text(photo.creator),
        rights:license(label,photo.license_url), page:httpsUrl(photo.foreign_landing_url,link => ['www.flickr.com','flickr.com'].includes(link.hostname))?.href,
        mime, url:photo.url, thumb:photo.thumbnail, width:photo.width, height:photo.height, size:photo.filesize, kind:'image'});
    });
    return {items, next:page < data.page_count ? offset + flickrPageSize : undefined};
  }

  async function search(params, signal) {
    const provider = params.get('source');
    const kind = params.get('kind');
    const query = (params.get('q') ?? '').trim();
    const offset = Number(params.get('offset') ?? 0);
    if (!['commons','flickr'].includes(provider) || !['image','video'].includes(kind) ||
        (provider === 'flickr' && kind !== 'image') || query.length < 2 || query.length > 100 ||
        !Number.isInteger(offset) || offset < 0 || offset > maxOffset) throw new CatalogError(400,'Проверь запрос и выбранный источник.');
    const {items,next} = provider === 'commons' ? await commons(query,kind,offset,signal) : await flickr(query,offset,signal);
    const now = Date.now();
    for (const [id,saved] of resultsById) if (saved.expires < now) resultsById.delete(id);
    const results = items.filter(Boolean).map(({url,thumb,...metadata}) => {
      const id = randomUUID();
      resultsById.set(id, {provider,url,thumb,mime:metadata.mime,expires:now + 20 * 60 * 1000});
      return {id,...metadata,preview:Boolean(thumb)};
    });
    while (resultsById.size > 384) resultsById.delete(resultsById.keys().next().value);
    return {results,next:Number.isInteger(next) && next > offset && next <= maxOffset ? next : null};
  }

  async function openMedia(url, provider, thumb, signal) {
    for (let hop = 0; hop < 4; hop++) {
      if (!url || !assetAllowed(provider,thumb,url)) break;
      const response = await fetchOnline(url,{headers:{'User-Agent':client,Accept:'image/*,video/*'},redirect:'manual',signal});
      if (response.status >= 300 && response.status < 400) {
        const destination = response.headers.get('location');
        await response.body?.cancel();
        url = destination && httpsUrl(new URL(destination,url).href,link => assetAllowed(provider,thumb,link));
        continue;
      }
      if (response.ok && response.body) return response;
      await response.body?.cancel();
      break;
    }
    throw new CatalogError(502,'Сайт не отдал файл. Открой оригинал или выбери другие обои.');
  }

  async function media(id, thumb, response, signal) {
    const saved = keyPattern.test(id) && resultsById.get(id);
    if (!saved || saved.expires < Date.now() || (thumb && !saved.thumb)) {
      throw new CatalogError(404,'Результат недоступен. Повтори поиск.');
    }
    const upstream = await openMedia(thumb ? saved.thumb : saved.url,saved.provider,thumb,signal);
    const limit = thumb ? maxThumbnail : maxDownload;
    const mime = upstream.headers.get('content-type')?.split(';',1)[0];
    if (Number(upstream.headers.get('content-length')) > limit ||
        (thumb ? mediaTypes.get(mime)?.[0] !== 'image' : mime !== saved.mime)) {
      await upstream.body.cancel();
      throw new CatalogError(415,'Источник отдал неподдерживаемый формат или слишком большой файл.');
    }
    let received = 0;
    const bounded = new Transform({transform(chunk, encoding, callback) {
      received += chunk.length;
      callback(received > limit ? Error('Online media exceeded the size limit') : null,chunk);
    }});
    response.writeHead(200,{'Content-Type':mime});
    await pipeline(Readable.fromWeb(upstream.body),bounded,response,{signal});
  }

  return {search, media};
}

export function catalogFailure(error) {
  return error instanceof CatalogError ? error : new CatalogError(502,'Не удалось связаться с источником. Проверь интернет и повтори запрос.');
}
