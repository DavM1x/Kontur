const byId = (id) => document.getElementById(id);
const library = [];
const tiles = byId('tiles');
const media = byId('media');
const search = byId('search');
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const motion = byId('motion');
const easing = 'cubic-bezier(.22,1,.36,1)';
const desktopAvailable = location.protocol === 'http:' && location.hostname === '127.0.0.1';
let applyingWallpaper = false;
let videoRunning = false;
let section = 'library';
let visibleItems = [];
const favorites = new Set();
try {
  const stored = JSON.parse(localStorage.getItem('kontur.favorites') ?? '[]');
  if (Array.isArray(stored)) for (const key of stored) {
    if (typeof key === 'string' && /^(file|web):/.test(key)) favorites.add(key);
  }
} catch { /* Favorites still work for the current session. */ }

function syncSelection() {
  const index = visibleItems.indexOf(selected);
  byId('position').textContent = visibleItems.length ? (index + 1) + ' / ' + visibleItems.length : '0 / 0';
  byId('previous').disabled = byId('next').disabled = visibleItems.length < 2;
  byId('position').parentElement.hidden = visibleItems.length < 2;
  const favorite = byId('favorite');
  const saved = selected ? favorites.has(selected.key) : false;
  const label = saved ? 'Убрать из избранного' : 'В избранное';
  favorite.disabled = byId('fullscreen').disabled = !selected;
  favorite.setAttribute('aria-pressed', String(saved));
  favorite.setAttribute('aria-label', label);
  favorite.title = label;
  favorite.firstElementChild.textContent = saved ? '♥' : '♡';
}

function step(offset) {
  if (visibleItems.length < 2) return;
  const index = visibleItems.indexOf(selected);
  const next = (index + offset + visibleItems.length) % visibleItems.length;
  tiles.children[next].click();
}
let selected;
let toastTimer;
let dragDepth = 0;

function animate(element, frames, options) {
  if (motion?.checked && !reducedMotion.matches) {
    for (const animation of element.getAnimations()) animation.cancel();
    return element.animate(frames, { easing, ...options });
  }
}

function notify(message) {
  const toast = byId('toast');
  clearTimeout(toastTimer);
  toast.textContent = message;
  toast.hidden = false;
  animate(toast, [{ opacity: 0, transform: 'translateY(8px)' }, { opacity: 1, transform: 'none' }], { duration: 260 });
  toastTimer = setTimeout(() => { toast.hidden = true; }, 4000);
}

function select(item, direction = 0) {
  if (selected === item) return;
  selected = item;
  byId('title').textContent = item?.title ?? '';
  byId('title').hidden = !item;
  const credit = item?.credit;
  byId('source-details').hidden = !credit;
  if (credit) {
    byId('source-author').textContent = credit.author ? 'Автор: ' + credit.author : '';
    byId('source-license').textContent = credit.rights.label;
    if (credit.rights.url) byId('source-license').href = credit.rights.url;
    else byId('source-license').removeAttribute('href');
    byId('source-original').href = credit.page;
  }
  byId('type').hidden = !item;
  byId('type').textContent = item?.kind === 'web' ? 'Веб-обои' : item?.kind === 'video' ? 'Видео' : 'Фото';
  byId('apply').disabled = !item?.url;
  byId('preview-empty').hidden = Boolean(item?.url);
  byId('preview-message').textContent = item ? 'У проекта нет изображения предпросмотра' : 'Выбери обои в библиотеке';
  syncWallpaperAction();
  const current = media.firstElementChild;
  const previous = current?.classList.contains('pending-frame') ? media.lastElementChild : current;
  if (previous instanceof HTMLVideoElement) previous.pause();
  media.replaceChildren();
  if (item?.url) {
    const preview = document.createElement(item.kind === 'video' ? 'video' : 'img');
    if (preview instanceof HTMLVideoElement) {
      preview.muted = !byId('sound').checked;
      preview.loop = true;
      preview.autoplay = true;
      preview.playsInline = true;
    } else {
      preview.alt = '';
    }
    preview.addEventListener('error', () => {
      if (preview.parentNode === media) notify('Не удалось открыть предпросмотр.');
    });
    preview.src = item.url;
    media.append(preview);
    if (preview instanceof HTMLImageElement && previous instanceof HTMLImageElement &&
        previous.complete && previous.naturalWidth && motion?.checked && !reducedMotion.matches) {
      const backdrop = previous.cloneNode();
      backdrop.className = 'previous-frame';
      media.append(backdrop);
      preview.classList.add('pending-frame');
      preview.decode().catch(() => {}).then(() => {
        if (preview.parentNode !== media) return;
        preview.classList.remove('pending-frame');
        const transition = animate(preview, [
          { opacity: 0, transform: 'translateX(' + (direction * 10) + 'px) scale(1.02)' },
          { opacity: 1, transform: 'none' },
        ], { duration: 290 });
        if (transition) transition.finished.catch(() => {}).finally(() => backdrop.remove());
        else backdrop.remove();
      });
    }
  }
  animate(byId('title'), [{ opacity: 0, transform: 'translateY(13px)' }, { opacity: 1, transform: 'none' }], { duration: 330 });
}

function createTile(item, index, entrance) {
  const tile = document.createElement('button');
  tile.type = 'button';
  tile.className = 'tile';
  tile.dataset.favorite = favorites.has(item.key);
  tile.setAttribute('aria-pressed', String(item === selected));
  const thumb = document.createElement('span');
  thumb.className = 'thumb';
  if (item.kind !== 'video' && item.url) {
    const image = document.createElement('img');
    image.loading = 'lazy';
    image.src = item.url;
    image.alt = '';
    thumb.append(image);
  } else {
    thumb.textContent = item.kind === 'web' ? 'HTML' : '▶';
  }
  const title = document.createElement('b');
  title.textContent = item.title;
  const meta = document.createElement('small');
  meta.textContent = item.kind === 'web' ? 'Веб-обои' : item.kind === 'video' ? 'Видео' : 'Фото';
  tile.append(thumb, title, meta);
  tile.addEventListener('click', () => {
    select(item, Math.sign(index - visibleItems.indexOf(selected)));
    for (const button of tiles.querySelectorAll('button')) {
      button.setAttribute('aria-pressed', String(button === tile));
    }
    syncSelection();
  });
  tiles.append(tile);
  if (entrance && index < 4) {
    animate(tile, [{ opacity: 0, translate: '0 14px' }, { opacity: 1, translate: 'none' }], { duration: 220, delay: index * 24, fill: 'backwards' });
  }
}

function render({ entrance = false, preferred = selected } = {}) {
  const query = search.value.trim().toLocaleLowerCase('ru');
  const kind = byId("kind").value;
  const items = library.filter((item) => (!kind || item.kind === kind) && (section !== 'favorites' || favorites.has(item.key)) && item.title.toLocaleLowerCase('ru').includes(query));
  visibleItems = items;
  byId('count').textContent = items.length;
  select(items.includes(preferred) ? preferred : items[0] ?? null);
  syncSelection();
  tiles.replaceChildren();
  items.forEach((item, index) => createTile(item, index, entrance));
  if (!items.length) {
    const filtered = Boolean(query || kind);
    const showingFavorites = section === 'favorites';
    const empty = document.createElement('h3');
    empty.textContent = filtered ? 'Ничего не найдено' : showingFavorites ? 'Избранное пусто' : 'Библиотека пуста';
    const hint = document.createElement('p');
    hint.textContent = filtered ? 'Попробуй другое имя или формат.' : showingFavorites ? 'Нажми на сердце в предпросмотре, чтобы добавить обои.' : 'Перетащи сюда фото, видео или архив с обоями.';
    const action = document.createElement('button');
    action.type = 'button';
    action.className = 'empty-action';
    action.textContent = filtered ? 'Сбросить фильтры' : showingFavorites ? 'В библиотеку' : 'Добавить файлы';
    action.onclick = () => {
      if (filtered) {
        search.value = '';
        byId('kind').value = '';
        render();
        search.focus();
      } else if (showingFavorites) {
        openTab('library');
        byId('library-tab').focus();
      } else byId('files').click();
    };
    const emptyState = document.createElement('div');
    emptyState.className = 'empty-state';
    emptyState.append(empty, hint, action);
    tiles.append(emptyState);
  }
}

function openTab(nextSection, preferred) {
  section = nextSection;
  byId('workbench').hidden = false;
  byId('online').hidden = true;
  byId('online-tab').setAttribute('aria-pressed','false');
  search.value = '';
  byId('kind').value = '';
  byId('library-tab').setAttribute('aria-pressed', String(section === 'library'));
  byId('favorites-tab').setAttribute('aria-pressed', String(section === 'favorites'));
  byId('collection-title').textContent = section === 'favorites' ? 'Избранное' : 'Библиотека';
  render({ entrance: true, preferred });
}

const supportedFile = /\.(mp4|webm|jpe?g|png|webp)$/i;
let libraryDatabase;
function openLibraryDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('kontur-library', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('files', { keyPath: 'key' });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
function libraryTransaction(database, mode, operation) {
  return new Promise((resolve, reject) => {
    const tx = database.transaction('files', mode);
    const request = operation(tx.objectStore('files'));
    tx.oncomplete = () => resolve(request?.result);
    tx.onabort = () => reject(tx.error);
  });
}
function addStoredFile(record) {
  const item = { key:record.key, title:record.title, kind:record.kind, file:record.file, credit:record.credit, url:URL.createObjectURL(record.file) };
  library.push(item);
  return item;
}
async function restoreLibrary() {
  try {
    libraryDatabase = await openLibraryDatabase();
    const records = await libraryTransaction(libraryDatabase, 'readonly', (store) => store.getAll());
    for (const record of records) if (!record.sceneSnapshot) addStoredFile(record).saved = true;
    render();
  } catch { libraryDatabase = undefined; }
}
const libraryReady = Promise.resolve().then(restoreLibrary);
async function importFiles(files, projectTitle, credit) {
  await libraryReady;
  const records = Array.from(files).filter((file) => supportedFile.test(file.name)).map((file) => ({
    key: 'file:' + crypto.randomUUID(),
    title: projectTitle || file.name.replace(/\.[^.]+$/, ''),
    kind: /\.(mp4|webm)$/i.test(file.name) ? 'video' : 'image',
    file,
    credit,
  }));
  if (!records.length) { notify('Выбери MP4, WebM, JPG, PNG или WebP.'); return; }
  let saved = false;
  if (libraryDatabase) {
    try {
      await libraryTransaction(libraryDatabase, 'readwrite', (store) => {
        for (const record of records) store.add(record);
      });
      saved = true;
    } catch { /* The preview remains usable if storage is full. */ }
  }
  const items = records.map(addStoredFile);
  if (saved) for (const item of items) item.saved = true;
  openTab('library', items.at(-1));
  notify(saved ? 'Добавлено в локальную библиотеку.' : 'Хранилище недоступно. Файлы останутся до закрытия окна.');
}

function addWebProject(project) {
  const key = 'web:' + project.id;
  const existing = library.find(item => item.key === key);
  if (existing) return existing;
  const item = {
    key, kind:'web', title:project.title, webId:project.id,
    url:project.preview ? '/web-preview/' + project.id : null,
  };
  library.push(item);
  return item;
}
async function restoreWebProjects() {
  if (!desktopAvailable) return;
  try {
    const response = await fetch('/web-list');
    if (!response.ok) return;
    (await response.json()).forEach(addWebProject);
    render();
  } catch {}
}
async function importWebBundle(body, format) {
  if (!desktopAvailable) { notify('Открой «Контур» через ярлык Windows, чтобы импортировать веб-обои.'); return; }
  notify('Читаю веб-проект…');
  try {
    const response = await fetch('/web-import', {
      method:'POST',
      headers:{'X-Kontur-Action':'set-web','X-Kontur-Format':format,'Content-Type':'application/octet-stream'},
      body,
    });
    if (!response.ok) throw Error(await response.text());
    const item = addWebProject(await response.json());
    openTab('library',item);
    notify('Веб-обои добавлены. Нажми «Запустить веб-обои».');
  } catch(error) { notify(error.message); }
}
function bundleFolder(files) {
  const entries = files.map(file => ({name:file.webkitRelativePath ? file.webkitRelativePath.split('/').slice(1).join('/') : file.name,size:file.size}));
  const index = new TextEncoder().encode(JSON.stringify(entries));
  const header = new DataView(new ArrayBuffer(4));
  header.setUint32(0,index.byteLength,true);
  return new Blob([header.buffer,index,...files]);
}
const archiveExtension = /\.(zip|m?pkg|rar)$/i;
async function importPackage(read, uploadWeb) {
  notify('Читаю файлы проекта…');
  try {
    const {file, title, web} = await read();
    if (web) { await uploadWeb(); return; }
    await importFiles([file], title);
  } catch (error) {
    notify(error.message || 'Не удалось открыть архив Wallpaper Engine.');
  }
}
async function importPicked(files) {
  const media = files.filter((file) => !archiveExtension.test(file.name));
  if (media.length) await importFiles(media);
  for (const file of files) {
    if (/\.m?pkg$/i.test(file.name)) notify('Сцены Wallpaper Engine не поддерживаются.');
    else if (/\.rar$/i.test(file.name)) await importWebBundle(file,'rar');
    else if (archiveExtension.test(file.name)) await importPackage(() => konturArchives.importArchive(file), () => importWebBundle(file,'zip'));
  }
}

byId('import-project').onclick = () => byId('project-files').click();
byId('project-files').onchange = (event) => {
  const files = Array.from(event.target.files);
  event.target.value = '';
  if (files.length) importPackage(() => konturArchives.importFolder(files), () => importWebBundle(bundleFolder(files),'folder'));
};

byId('library-tab').onclick = () => openTab('library');
byId('favorites-tab').onclick = () => openTab('favorites');
byId('previous').onclick = () => step(-1);
byId('next').onclick = () => step(1);
byId('favorite').onclick = () => {
  if (!selected) return;
  const key = selected.key;
  if (favorites.has(key)) favorites.delete(key);
  else favorites.add(key);
  try { localStorage.setItem('kontur.favorites', JSON.stringify([...favorites].filter((key) => !key.startsWith('file:') || library.some((item) => item.key === key && item.saved)))); }
  catch { /* The current session remains usable. */ }
  render();
  const favorite = byId('favorite');
  if (!favorite.disabled) {
    favorite.focus();
    animate(favorite.firstElementChild, [
      { transform: 'scale(.86)' }, { transform: 'scale(1.14)', offset: .55 }, { transform: 'scale(1)' },
    ], { duration: 220 });
  }
};
const stage = byId('stage');
const fullscreen = byId('fullscreen');
fullscreen.onclick = async () => {
  try {
    if (document.fullscreenElement === stage) await document.exitFullscreen();
  } catch {
    notify('Полноэкранный режим недоступен.');
  }
};
document.addEventListener('fullscreenchange', () => {
  if (document.fullscreenElement === stage) fullscreen.focus();
  else byId('apply').focus();
});
window.addEventListener('keydown', (event) => {
  if (event.altKey || event.ctrlKey || event.metaKey || byId('prefs').open ||
      event.target.matches?.('input, select, textarea, [contenteditable]')) return;
  if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
    if (visibleItems.length < 2) return;
    event.preventDefault();
    step(event.key === 'ArrowLeft' ? -1 : 1);
  }
});
search.oninput = () => render();
byId('kind').onchange = () => render();
byId('import').onclick = () => byId('files').click();
byId('files').onchange = (event) => {
  importPicked(Array.from(event.target.files));
  event.target.value = '';
};
byId('settings').onclick = () => {
  const prefs = byId('prefs');
  prefs.showModal();
  animate(prefs, [{ opacity: 0, transform: 'translateY(10px)' }, { opacity: 1, transform: 'none' }], { duration: 270 });
};
byId('fit').onchange = (event) => media.style.setProperty('--fit', event.target.value);
byId('sound').onchange = (event) => {
  const video = media.querySelector('video');
  if (video) video.muted = !event.target.checked;
};
motion?.addEventListener('change', (event) => {
  document.documentElement.dataset.motion = event.target.checked ? 'on' : 'off';
  if (!event.target.checked) document.getAnimations().forEach((animation) => animation.cancel());
});
reducedMotion.addEventListener('change', () => {
  if (reducedMotion.matches) document.getAnimations().forEach((animation) => animation.cancel());
});
byId('apply').onclick = async () => {
  if (!selected?.url) return;
  try { await stage.requestFullscreen(); }
  catch { notify('Полноэкранный режим недоступен.'); }
};
window.addEventListener('dragenter', (event) => {
  if (!event.dataTransfer.types.includes('Files')) return;
  event.preventDefault();
  dragDepth++;
  byId('drop').hidden = false;
});
window.addEventListener('dragover', (event) => {
  if (event.dataTransfer.types.includes('Files')) event.preventDefault();
});
window.addEventListener('dragleave', () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (!dragDepth) byId('drop').hidden = true;
});
window.addEventListener('drop', (event) => {
  if (!event.dataTransfer.types.includes('Files')) return;
  event.preventDefault();
  dragDepth = 0;
  byId('drop').hidden = true;
  importPicked(Array.from(event.dataTransfer.files));
});

openTab('library');






function webFps(id) {
  try {
    const value = localStorage.getItem('kontur.webFps.' + id);
    if (['15','30','60'].includes(value)) return value;
  } catch {}
  return '30';
}
byId('web-fps').addEventListener('change', async (event) => {
  if (selected?.kind !== 'web') return;
  const value = event.target.value;
  const id = selected.webId;
  try { localStorage.setItem('kontur.webFps.' + id,value); } catch {}
  if (!desktopAvailable) return;
  try {
    const response = await fetch('/web-options', {
      method:'POST',headers:{'X-Kontur-Action':'set-web','X-Kontur-Project':id,'X-Kontur-Fps':value},
    });
    if (!response.ok) throw Error(await response.text());
  } catch (error) { notify(error.message); }
});
function syncWallpaperAction() {
  const button = byId('wallpaper');
  button.hidden = !desktopAvailable || !selected;
  const isWeb = selected?.kind === 'web';
  byId('stage-controls').hidden = !selected;
  byId('fit-label').hidden = byId('fit').hidden = isWeb;
  byId('web-fps-label').hidden = byId('web-fps').hidden = !isWeb;
  if (isWeb) byId('web-fps').value = webFps(selected.webId);
  const video = selected?.kind === 'video' && /\.(mp4|webm)$/i.test(selected.file?.name ?? '');
  button.disabled = applyingWallpaper || (selected?.kind !== 'image' && selected?.kind !== 'web' && !video);
  button.title = selected?.kind === 'video' && !video ? 'Для рабочего стола выбери MP4 или WebM' : '';
  button.textContent = applyingWallpaper ? 'Устанавливаю…' : selected?.kind === 'web' ? 'Запустить веб-обои' : video ? 'Запустить видеообои' : 'Установить на рабочий стол';
  byId('stop-video').hidden = !desktopAvailable || !videoRunning;
  byId('playback').hidden = byId('stop-video').hidden;
  byId('stop-video').disabled = applyingWallpaper;
}

byId('wallpaper').addEventListener('click', async () => {
  if (!desktopAvailable || byId('wallpaper').disabled || byId('wallpaper').hidden) return;
  const item = selected;
  applyingWallpaper = true;
  syncWallpaperAction();
  try {
    if (item.kind === 'web') {
      const response = await fetch('/web-wallpaper', {
        method:'POST', headers:{'X-Kontur-Action':'set-web','X-Kontur-Project':item.webId,'X-Kontur-Fps':webFps(item.webId)},
      });
      if (!response.ok) throw Error(await response.text());
      videoRunning = true;
      notify('Веб-обои запущены.');
      return;
    }
    if (item.kind === 'video') {
      const response = await fetch('/video-wallpaper', {
        method: 'POST',
        headers: {'Content-Type': /\.webm$/i.test(item.file.name) ? 'video/webm' : 'video/mp4', 'X-Kontur-Action':'set-video'},
        body: item.file,
      });
      if (!response.ok) throw Error(await response.text());
      videoRunning = true;
      notify('Видеообои запущены.');
      return;
    }
    const image = new Image();
    image.src = item.url;
    await image.decode();
    const ratio = Math.min(1, 4096 / Math.max(image.naturalWidth, image.naturalHeight));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(image.naturalWidth * ratio));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * ratio));
    canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
    if (!blob) throw Error('Не удалось подготовить изображение.');
    const response = await fetch('/wallpaper', {
      method: 'POST',
      headers: {'Content-Type':'image/png', 'X-Kontur-Action':'set-wallpaper'},
      body: blob,
    });
    if (!response.ok) throw Error(await response.text());
    videoRunning = false;
    notify('Установлены обои «' + item.title + '».');
  } catch (error) {
    notify(error instanceof TypeError ? 'Связь с Windows потеряна. Перезапусти «Контур».' : error.message);
  } finally {
    applyingWallpaper = false;
    syncWallpaperAction();
  }
});
let videoStatusRetry;
async function refreshVideoStatus() {
  clearTimeout(videoStatusRetry);
  if (applyingWallpaper) return;
  try {
    const response = await fetch('/video-status');
    if (response.ok) {
      const status = await response.text();
      if (status === 'starting') {
        videoStatusRetry = setTimeout(refreshVideoStatus, 750);
        return;
      }
      videoRunning = status === 'playing';
      syncWallpaperAction();
    }
  } catch {}
}
byId('stop-video').onclick = async () => {
  try {
    const response = await fetch('/stop-video', {method:'POST', headers:{'X-Kontur-Action':'set-video'}});
    if (!response.ok) throw Error(await response.text());
    videoRunning = false;
    syncWallpaperAction();
    notify('Живые обои остановлены.');
  } catch (error) { notify(error.message); }
};
if (desktopAvailable) {
  restoreWebProjects();
  refreshVideoStatus();
  setInterval(() => fetch('/status').catch(() => {}), 60_000);
  window.addEventListener('focus', refreshVideoStatus);
}
