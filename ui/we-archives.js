/* Local Wallpaper Engine imports. Archive entries stay in the browser as Blob slices. */
(() => {
  const decoder = new TextDecoder();
  const maxMedia = 512 * 1024 * 1024;
  const maxJson = 1024 * 1024;
  const maxTable = 16 * 1024 * 1024;
  const videoExtension = /\.(mp4|webm)$/i;

  const bytes = (blob, from, to) => blob.slice(from, to).arrayBuffer();
  function pathKey(raw) {
    const path = raw.replaceAll('\\', '/').replace(/^(?:\.\/)+/, '');
    if (!path || /^[\/]|:|\0/.test(path) || path.split('/').some((part) => part === '..')) return '';
    return path.toLowerCase();
  }
  function put(entries, key, value) {
    if (!key) throw Error('Недопустимый путь внутри архива.');
    if (entries.has(key)) throw Error('В архиве есть одинаковые имена файлов.');
    entries.set(key, value);
  }
  function mediaFile(blob, filename) {
    const type = /\.webm$/i.test(filename) ? 'video/webm' : 'video/mp4';
    return new File([blob], filename.split('/').at(-1), {type});
  }
  async function zipEntries(blob) {
    const tailStart = Math.max(0, blob.size - 65557);
    const tail = new DataView(await bytes(blob, tailStart));
    let end = tail.byteLength - 22;
    while (end >= 0 && !(tail.getUint32(end, true) === 0x06054b50 &&
      end + 22 + tail.getUint16(end + 20, true) === tail.byteLength)) end--;
    if (end < 0) throw Error('Не найден каталог ZIP.');
    const count = tail.getUint16(end + 10, true);
    const size = tail.getUint32(end + 12, true);
    const offset = tail.getUint32(end + 16, true);
    if (tail.getUint16(end + 4, true) || tail.getUint16(end + 6, true) ||
        tail.getUint16(end + 8, true) !== count || !count || count === 65535 ||
        size > maxTable || offset + size > tailStart + end) throw Error('Этот тип ZIP пока не поддерживается.');
    const data = await bytes(blob, offset, offset + size);
    const table = new DataView(data);
    const entries = new Map();
    let cursor = 0;
    for (let i = 0; i < count; i++) {
      if (cursor + 46 > size || table.getUint32(cursor, true) !== 0x02014b50) throw Error('Повреждён каталог ZIP.');
      const flags = table.getUint16(cursor + 8, true);
      const method = table.getUint16(cursor + 10, true);
      const packed = table.getUint32(cursor + 20, true);
      const unpacked = table.getUint32(cursor + 24, true);
      const nameLength = table.getUint16(cursor + 28, true);
      const endOfEntry = cursor + 46 + nameLength + table.getUint16(cursor + 30, true) + table.getUint16(cursor + 32, true);
      const local = table.getUint32(cursor + 42, true);
      if (!nameLength || endOfEntry > size) throw Error('Повреждено имя файла ZIP.');
      const name = decoder.decode(new Uint8Array(data, cursor + 46, nameLength));
      cursor = endOfEntry;
      if (name.endsWith('/')) continue;
      put(entries, pathKey(name), {
        size: unpacked,
        async read(limit) {
          if (unpacked > limit || packed > maxMedia || local + 30 > offset) throw Error('Файл внутри ZIP слишком большой или повреждён.');
          if (flags & 1) throw Error('ZIP защищён паролем.');
          const header = new DataView(await bytes(blob, local, local + 30));
          if (header.getUint32(0, true) !== 0x04034b50 || header.getUint16(8, true) !== method) throw Error('Повреждён заголовок файла ZIP.');
          const start = local + 30 + header.getUint16(26, true) + header.getUint16(28, true);
          if (start + packed > offset) throw Error('Файл выходит за пределы ZIP.');
          const compressed = blob.slice(start, start + packed);
          if (method === 0 && packed === unpacked) return compressed;
          if (method !== 8) throw Error('Метод сжатия ZIP пока не поддерживается.');
          const reader = compressed.stream().pipeThrough(new DecompressionStream('deflate-raw')).getReader();
          const result = [];
          let received = 0;
          try {
            while (true) {
              const {value, done} = await reader.read();
              if (done) break;
              received += value.byteLength;
              if (received > unpacked) throw Error('Размер файла ZIP не совпадает с каталогом.');
              result.push(value);
            }
            if (received !== unpacked) throw Error('ZIP оборван.');
            return new Blob(result);
          } finally {
            await reader.cancel().catch(() => {});
          }
        },
      });
    }
    return entries;
  }

  async function pickMedia(entries, fallbackTitle) {
    const manifests = [...entries.keys()].filter((name) => /(^|\/)project\.json$/.test(name));
    const projectPath = manifests.sort((a, b) => a.split('/').length - b.split('/').length)[0];
    let title = fallbackTitle;
    if (projectPath) {
      const manifest = await entries.get(projectPath).read(maxJson);
      let project;
      try { project = JSON.parse((await manifest.text()).replace(/^\uFEFF/, '')); }
      catch { throw Error('Не удалось прочитать project.json.'); }
      if (!project || typeof project !== 'object') throw Error('Некорректный project.json.');
      title = typeof project.title === 'string' ? project.title.trim().slice(0, 160) || title : title;
      const type = String(project.type).toLowerCase();
      if (type === 'scene') throw Error('Сцены Wallpaper Engine не поддерживаются. Можно импортировать фото, видео или веб-обои.');
      if (type === 'web') return {web:true,title};
      if (type === 'application') throw Error('Исполняемые обои Wallpaper Engine не поддерживаются.');
      const name = pathKey(String(project.file ?? ''));
      const target = projectPath.slice(0, -'project.json'.length) + name;
      const entry = name && entries.get(target);
      if (type === 'video') {
        if (!entry || !videoExtension.test(name)) throw Error('Видео из project.json не найдено.');
        return {file: mediaFile(await entry.read(maxMedia), name), title};
      }
    }
    const files = [...entries].sort((a, b) => b[1].size - a[1].size);
    const video = files.find(([name]) => videoExtension.test(name));
    if (video) return {file: mediaFile(await video[1].read(maxMedia), video[0]), title};
    if (files.some(([name]) => /\.m?pkg$/i.test(name))) throw Error('В архиве находится сцена Wallpaper Engine. Этот формат не поддерживается.');
    throw Error('В архиве нет поддерживаемого видео или веб-проекта.');
  }

  async function importArchive(file) {
    return pickMedia(await zipEntries(file),file.name.replace(/\.[^.]+$/, ''));
  }
  async function importFolder(files) {
    const entries = new Map();
    for (const file of files) {
      const path = pathKey(file.webkitRelativePath.split('/').slice(1).join('/'));
      put(entries, path, {size: file.size, async read(limit) {
        if (file.size > limit) throw Error('Файл проекта слишком большой.');
        return file;
      }});
    }
    return pickMedia(entries, files[0]?.webkitRelativePath.split('/')[0] || 'Проект Wallpaper Engine');
  }

  globalThis.konturArchives = {importArchive, importFolder};
})();
