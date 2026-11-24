import { createServer } from 'node:http';
import { readFile, writeFile, mkdir, mkdtemp, readdir, rename, rm, stat, open } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { join, basename, extname, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { execFile, spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

import { webLibrary } from './web-library.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.KONTUR_PORT || 48371);
const host = '127.0.0.1:' + port;
const origin = 'http://' + host;
const run = promisify(execFile);
const types = { '.html':'text/html; charset=utf-8', '.css':'text/css; charset=utf-8', '.js':'text/javascript; charset=utf-8', '.png':'image/png', '.jpg':'image/jpeg', '.wav':'audio/wav' };
const web = webLibrary(root);
const pngHeader = Buffer.from([137,80,78,71,13,10,26,10]);
const videoDirectory = join(root, 'runtime', 'active-video');
const selectionPath = join(videoDirectory, 'selected.json');
const managedVideo = /^[a-f0-9-]{36}\.(mp4|webm)$/;
const maxVideo = 512 * 1024 * 1024;
const validateOnly = process.env.KONTUR_VALIDATE_ONLY === '1';
const playingFiles = new Set();
let busy = false;
let videoPlayer;
let selectedVideo;
let pendingVideo;
let restoringVideo = false;
let lastUse = Date.now();

function reply(response, status, body = '') {
  response.writeHead(status, { 'Content-Type':'text/plain; charset=utf-8' });
  response.end(body);
}
function stopVideo() { if (videoPlayer) videoPlayer.kill(); }
function wait(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function validVideo(path, expectedSize) {
  const info = await stat(path);
  if (!info.isFile() || info.size < 24 || info.size > maxVideo || (expectedSize !== undefined && info.size !== expectedSize)) return false;
  const header = Buffer.alloc(12);
  const file = await open(path, 'r');
  try { await file.read(header, 0, header.length, 0); } finally { await file.close(); }
  return extname(path) === '.webm' ? header.readUInt32BE(0) === 0x1a45dfa3 : header.toString('ascii',4,8) === 'ftyp';
}

async function discardVideo(path) {
  if (path && path !== selectedVideo && path !== pendingVideo && !playingFiles.has(path)) await rm(path, {force:true}).catch(() => {});
}

async function selectVideo(path) {
  const previous = selectedVideo;
  if (path) {
    const pending = join(videoDirectory, 'selection-' + randomUUID() + '.tmp');
    try {
      await writeFile(pending, JSON.stringify({file:basename(path)}), {flag:'wx'});
      await rename(pending, selectionPath);
    } finally { await rm(pending, {force:true}).catch(() => {}); }
  } else {
    await rm(selectionPath, {force:true});
  }
  selectedVideo = path;
  await discardVideo(previous);
}

async function launchVideo(video) {
  const directory = await mkdtemp(join(tmpdir(), 'kontur-player-'));
  const ready = join(directory, 'ready');
  async function clean() {
    await rm(ready, {force:true}).catch(() => {});
    await rm(directory).catch(() => {});
  }
  let child;
  let active = false;
  let starting = true;
  try {
    child = spawn('powershell.exe', ['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass',
      '-File',join(root,'ui','video-wallpaper.ps1'),'-Path',video,'-ReadyPath',ready,'-BridgeOrigin',origin],
      {windowsHide:true,stdio:['ignore','ignore','pipe']});
    active = true;
    playingFiles.add(video);
    let diagnostics = '';
    child.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk.toString()).slice(-2500); });
    child.once('close', () => {
      active = false;
      playingFiles.delete(video);
      if (videoPlayer === child) videoPlayer = undefined;
      if (!starting) void clean();
      void discardVideo(video);
    });
    child.once('error', error => { diagnostics += error.message; });
    let status;
    for (let attempt = 0; attempt < 68 && active; attempt++) {
      status = await readFile(ready,'utf8').catch(() => '');
      if (status === 'playing' && active) return {child};
      if (status === 'desktop-error' || status === 'player-error') break;
      await wait(250);
    }
    status = await readFile(ready,'utf8').catch(() => status);
    child.kill();
    if (diagnostics) console.error(diagnostics);
    const desktopUnavailable = status === 'desktop-error' || /Desktop|Explorer/.test(diagnostics);
    const message = desktopUnavailable
      ? 'Windows не дала разместить окно за значками рабочего стола.'
      : status === 'player-error' || diagnostics
        ? 'Не удалось запустить видеодвижок mpv.'
        : 'mpv не начал воспроизведение файла. Проверь, открывается ли видео в обычном плеере.';
    return {message, desktopUnavailable};
  } catch (error) {
    if (child) child.kill();
    throw error;
  } finally {
    starting = false;
    if (!active) await clean();
  }
}

async function startVideo(request, response) {
  const length = Number(request.headers['content-length']);
  if (!Number.isSafeInteger(length) || length < 24 || length > maxVideo) {
    return reply(response, 413, 'Видео должно занимать не больше 512 МБ.');
  }
  if (busy) return reply(response, 409, 'Обои уже устанавливаются.');
  busy = true;
  const extension = request.headers['content-type'] === 'video/webm' ? '.webm' : '.mp4';
  const video = join(videoDirectory, randomUUID() + extension);
  pendingVideo = video;
  let child;
  try {
    await mkdir(videoDirectory, {recursive:true});
    await pipeline(request, createWriteStream(video, {flags:'wx'}));
    if (!await validVideo(video, length)) return reply(response, 400, 'Формат видео не соответствует расширению MP4 или WebM.');
    if (validateOnly) return reply(response, 200);
    const playback = await launchVideo(video);
    if (!playback.child) return reply(response, 503, playback.message);
    child = playback.child;
    await selectVideo(video);
    stopVideo();
    videoPlayer = child.exitCode === null && child.signalCode === null ? child : undefined;
    lastUse = Date.now();
    return reply(response, 200);
  } catch (error) {
    if (child) child.kill();
    console.error(error.message);
    return reply(response, 500, 'Windows не удалось запустить видеообои.');
  } finally {
    pendingVideo = undefined;
    busy = false;
    await discardVideo(video);
  }
}

function jsonReply(response, data) {
  response.writeHead(200, {'Content-Type':'application/json; charset=utf-8'});
  return response.end(JSON.stringify(data));
}
function webFps(request) {
  const value = Number(request.headers['x-kontur-fps'] ?? 30);
  return [15,30,60].includes(value) ? value : null;
}
async function changeWebFps(request, response) {
  const fps = webFps(request);
  if (!fps) return reply(response,400,'Недопустимая частота кадров.');
  if (!videoPlayer?.settings || videoPlayer.webId !== request.headers['x-kontur-project'])
    return reply(response,204);
  try {
    await writeFile(videoPlayer.settings,String(fps));
    return reply(response,204);
  } catch { return reply(response,503,'Не удалось обновить лимит кадров.'); }
}
async function startWeb(request, response) {
  if (busy) return reply(response,409,'Обои уже устанавливаются.');
  const id = request.headers['x-kontur-project'];
  const fps = webFps(request);
  if (!fps || typeof id !== 'string' || !/^[a-f0-9-]{36}$/.test(id)) return reply(response,400,'Некорректный проект.');
  busy = true;
  let job;
  let scratch;
  try {
    const project = await web.record(id);
    if (validateOnly) return reply(response,200);
    scratch = await mkdtemp(join(tmpdir(),'kontur-web-'));
    const ready = join(scratch,'ready');
    const settings = join(scratch,'fps');
    job = spawn('powershell.exe',['-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',
      join(root,'ui','web-wallpaper.ps1'),'-ProjectRoot',join(project.files,project.relative),'-Entry',project.entry,
      '-ReadyPath',ready,'-Profile',join(project.directory,'browser'),'-Fps',String(fps),
      '-ControlPath',settings,'-ManifestName',project.manifestName || 'project.json'],{windowsHide:true,stdio:['ignore','ignore','pipe']});
    let exited = false, diagnostics = '';
    job.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-2500); });
    const finished = () => {
      exited = true;
      if (videoPlayer === job) videoPlayer = undefined;
      Promise.all([ready,settings].map(file => rm(file,{force:true}))).then(() => rm(scratch)).catch(() => {});
    };
    job.once('error', finished);
    job.once('exit', finished);
    for (let i=0; i<84 && !exited; i++) {
      if (await readFile(ready,'utf8').catch(()=>'') === 'playing' && !exited) {
        await selectVideo(undefined);
        stopVideo();
        job.webId = id;
        job.settings = settings;
        videoPlayer = job;
        lastUse = Date.now();
        return reply(response,200);
      }
      await new Promise(resolve => setTimeout(resolve,250));
    }
    if (diagnostics) console.error(diagnostics);
    job.kill();
    return reply(response,503,'Веб-обои не запустились в WebView2.');
  } catch (error) {
    if (job) job.kill();
    else if (scratch) await rm(scratch).catch(() => {});
    console.error(error.message);
    return reply(response,500,'Не удалось открыть веб-проект.');
  } finally { busy = false; }
}

const server = createServer(async (request, response) => {
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
  if (request.headers.host !== host) return reply(response, 403);
  const path = request.url;
  if (request.method === 'GET') {
    if (path === '/web-list') return jsonReply(response,await web.list());
    if (path.startsWith('/web-preview/')) {
      try {
        const {content,type} = await web.preview(path.slice('/web-preview/'.length));
        response.writeHead(200,{'Content-Type':type,'Content-Length':content.length});
        return response.end(content);
      } catch { return reply(response,404); }
    }
    if (path === '/video-status') return reply(response, 200, videoPlayer ? 'playing' : restoringVideo ? 'starting' : 'idle');
    if (path === '/status') {
      lastUse = Date.now();
      return reply(response, 200, 'Kontur desktop bridge 9');
    }
    if (!/^\/(ui|assets)\/[a-z0-9-]+\.(html|css|js|png|jpg|wav)$/.test(path)) return reply(response, 404);
    try {
      const content = await readFile(join(root, path.slice(1)));
      lastUse = Date.now();
      response.writeHead(200, { 'Content-Type': types[extname(path)], 'Content-Length':content.length });
      return response.end(content);
    } catch { return reply(response, 404); }
  }
  if (request.method === 'POST' && ['/web-import','/web-wallpaper','/web-options'].includes(path)) {
    if (request.headers.origin !== origin || request.headers['x-kontur-action'] !== 'set-web') return reply(response,403);
    if (path === '/web-wallpaper') return startWeb(request,response);
    if (path === '/web-options') return changeWebFps(request,response);
    try { return jsonReply(response,await web.extract(request,request.headers['x-kontur-format'] || 'rar')); }
    catch (error) { return reply(response,400,error.message); }
  }
  if (request.method === 'POST' && ['/video-wallpaper','/stop-video'].includes(path)) {
    if (request.headers.origin !== origin || request.headers['x-kontur-action'] !== 'set-video') return reply(response, 403);
    if (path === '/stop-video') {
      if (busy) return reply(response, 409, 'Обои уже устанавливаются.');
      busy = true;
      try {
        if (!validateOnly) await selectVideo(undefined);
        stopVideo();
        return reply(response, 200);
      } catch (error) {
        console.error(error.message);
        return reply(response, 500, 'Не удалось сохранить остановку видеообоев.');
      } finally { busy = false; }
    }
    if (!['video/mp4','video/webm'].includes(request.headers['content-type'])) return reply(response, 415);
    return startVideo(request, response);
  }
  if (request.method !== 'POST' || path !== '/wallpaper') return reply(response, 404);
  if (request.headers.origin !== origin || request.headers['x-kontur-action'] !== 'set-wallpaper' ||
      request.headers['content-type'] !== 'image/png') return reply(response, 403);
  if (busy) return reply(response, 409, 'Обои уже устанавливаются.');
  const length = Number(request.headers['content-length']);
  if (!Number.isSafeInteger(length) || length < 24 || length > 24 * 1024 * 1024) return reply(response, 413, 'Файл слишком большой или пустой.');
  busy = true;
  let scratch;
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const png = Buffer.concat(chunks);
    if (png.length !== length || !png.subarray(0,8).equals(pngHeader) ||
        png.toString('ascii',12,16) !== 'IHDR' || !png.readUInt32BE(16) ||
        !png.readUInt32BE(20) || png.readUInt32BE(16) * png.readUInt32BE(20) > 18_000_000) {
      return reply(response, 400, 'Некорректное изображение.');
    }
    scratch = await mkdtemp(join(tmpdir(), 'kontur-wallpaper-'));
    const input = join(scratch, 'image.png');
    await writeFile(input, png);
    const args = ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(root,'ui','set-wallpaper.ps1'),'-ImagePath',input];
    if (validateOnly) args.push('-ValidateOnly');
    await run('powershell.exe', args, { windowsHide:true, timeout:15000 });
    if (!validateOnly) await selectVideo(undefined);
    stopVideo();
    lastUse = Date.now();
    reply(response, 200);
  } catch (error) {
    console.error(error.message);
    reply(response, 500, 'Windows не удалось установить обои.');
  } finally {
    busy = false;
    if (scratch) await rm(join(scratch,'image.png'), {force:true}).catch(() => {});
    if (scratch) await rm(scratch).catch(() => {});
  }
});
server.requestTimeout = 20000;
if (!validateOnly) {
  try {
    const selection = JSON.parse(await readFile(selectionPath, 'utf8'));
    if (typeof selection.file === 'string' && managedVideo.test(selection.file)) {
      const video = join(videoDirectory, selection.file);
      if (await validVideo(video)) selectedVideo = video;
    }
  } catch (error) { if (error.code !== 'ENOENT') console.error(error.message); }
  for (const name of await readdir(videoDirectory).catch(() => [])) {
    if (managedVideo.test(name) || /^selection-[a-f0-9-]{36}\.tmp$/.test(name)) await discardVideo(join(videoDirectory, name));
  }
}
busy = restoringVideo = Boolean(selectedVideo);
server.listen(port, '127.0.0.1', async () => {
  if (!selectedVideo) return;
  try {
    for (let attempt = 0; attempt < 4; attempt++) {
      const playback = await launchVideo(selectedVideo);
      if (playback.child) {
        videoPlayer = playback.child;
        return;
      }
      if (!playback.desktopUnavailable || attempt === 3) break;
      await wait(2500);
    }
  } catch (error) { console.error(error.message); }
  finally { busy = restoringVideo = false; }
});
setInterval(() => {
  if (!busy && !videoPlayer && Date.now() - lastUse > 15 * 60 * 1000) server.close();
}, 60_000).unref();
