import { mkdir, mkdtemp, readdir, readFile, writeFile, rm, stat, rename, realpath, open } from 'node:fs/promises';
import { createReadStream, createWriteStream } from 'node:fs';
import { join, resolve, sep, extname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pipeline } from 'node:stream/promises';

const run = promisify(execFile);
const maxArchive = 64 * 1024 * 1024;
const maxExpanded = 192 * 1024 * 1024;
const formats = new Set(['rar','zip','folder']);
const guid = /^[a-f0-9-]{36}$/;
function safeFile(name) {
  return typeof name === 'string' && name.length > 0 && !/[\\:<>""|?*\x00-\x1f]/.test(name) &&
    name.split('/').every(part => part && part !== '.' && part !== '..' && !/[. ]$/.test(part) && !/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(part));
}

export function webLibrary(root) {
  const library = join(root, 'runtime', 'web-wallpapers');
  async function record(id) {
    if (!guid.test(id)) throw Error('Некорректный ID веб-обоев.');
    const directory = join(library, id);
    const meta = JSON.parse(await readFile(join(directory, 'metadata.json'), 'utf8'));
    if (meta.scene === true) throw Error('Сцены Wallpaper Engine больше не поддерживаются.');
    return {...meta, id, directory, files:join(directory,'files')};
  }
  async function unpackArchive(archive, target, format) {
    const handle = await open(archive,'r');
    const signature = Buffer.alloc(8);
    try { await handle.read(signature,0,signature.length,0); } finally { await handle.close(); }
    const expected = format === 'rar' ? Buffer.from([82,97,114,33,26,7]) : Buffer.from([80,75,3,4]);
    if (!signature.subarray(0,expected.length).equals(expected)) throw Error('Формат архива не совпадает с расширением.');
    const options = {windowsHide:true, timeout:15000, maxBuffer:1024 * 1024};
    const names = (await run('tar.exe',['-tf',archive],options)).stdout.trimEnd().split(/\r?\n/);
    const info = (await run('tar.exe',['-tvf',archive],options)).stdout.trimEnd().split(/\r?\n/);
    if (names.length !== info.length || names.length > 2500) throw Error('В архиве слишком много файлов.');
    const seen = new Set();
    let total = 0;
    for (let i = 0; i < names.length; i++) {
      const path = names[i].replace(/\/$/, '');
      const kind = info[i][0];
      const match = /^[d-][^\s]*\s+\d+\s+\S+\s+\S+\s+(\d+)\s/.exec(info[i]);
      if (!safeFile(path) || !match || (kind !== '-' && kind !== 'd') || seen.has(path.toLowerCase())) {
        throw Error('В архиве есть недопустимый путь, ссылка или повторяющееся имя.');
      }
      seen.add(path.toLowerCase());
      total += Number(match[1]);
      if (total > maxExpanded) throw Error('Объём файлов после распаковки слишком большой.');
    }
    await run('tar.exe', ['-xf',archive,'-C',target,'--no-same-owner','--no-same-permissions'],options);
    return names;
  }

  async function unpackFolder(bundle, target, length) {
    const handle = await open(bundle,'r');
    let entries, offset;
    try {
      const header = Buffer.alloc(4);
      if ((await handle.read(header,0,4,0)).bytesRead !== 4) throw Error('Нет каталога файлов проекта.');
      const size = header.readUInt32LE(0);
      if (!size || size > 1024 * 1024 || 4+size > length) throw Error('Недопустимый каталог файлов проекта.');
      const data = Buffer.alloc(size);
      if ((await handle.read(data,0,size,4)).bytesRead !== size) throw Error('Каталог файлов оборван.');
      entries = JSON.parse(data);
      offset = 4+size;
    } finally { await handle.close(); }
    if (!Array.isArray(entries) || !entries.length || entries.length > 2500) throw Error('Недопустимое число файлов проекта.');
    const seen = new Set();
    const names = [];
    for (const item of entries) {
      const name = item?.name;
      const size = item?.size;
      if (!safeFile(name) || seen.has(name.toLowerCase()) || !Number.isSafeInteger(size) || size < 0 || offset+size > length)
        throw Error('Некорректный файл проекта.');
      seen.add(name.toLowerCase());
      const output = join(target,name);
      await mkdir(resolve(output,'..'),{recursive:true});
      if (size) await pipeline(createReadStream(bundle,{start:offset,end:offset+size-1}),createWriteStream(output,{flags:'wx'}));
      else await writeFile(output,'',{flag:'wx'});
      names.push(name);
      offset += size;
    }
    if (offset !== length) throw Error('Размер папки проекта не совпадает с каталогом.');
    return names;
  }

  async function extract(request, format) {
    const length = Number(request.headers['content-length']);
    if (!formats.has(format)) throw Error('Выбери RAR, ZIP или папку проекта.');
    const limit = format === 'folder' ? maxExpanded + 1024 * 1024 : maxArchive;
    if (!Number.isSafeInteger(length) || length < 8 || length > limit) throw Error('Проект слишком большой или пустой.');
    await mkdir(library, {recursive:true});
    const scratch = await mkdtemp(join(library, '.import-'));
    try {
      const input = join(scratch, 'input.' + format);
      await pipeline(request, createWriteStream(input,{flags:'wx'}));
      if ((await stat(input)).size !== length) throw Error('Проект передан не полностью.');
      const stage = join(scratch, 'project');
      const target = join(stage, 'files');
      await mkdir(target, {recursive:true});
      const names = format === 'folder' ? await unpackFolder(input,target,length) : await unpackArchive(input,target,format);
      const manifests = names.filter(name => /(^|\/)project\.json$/i.test(name)).sort((a,b) => a.split('/').length-b.split('/').length);
      const manifestPath = manifests[0];
      if (!manifestPath) throw Error('В проекте нет project.json.');
      const relative = manifestPath.slice(0, -'project.json'.length);
      const projectRoot = resolve(target,relative);
      if (projectRoot !== target && !projectRoot.startsWith(target + sep)) throw Error('Недопустимая папка проекта.');
      const manifestFile = join(target,manifestPath);
      if ((await stat(manifestFile)).size > 1024*1024) throw Error('project.json слишком большой.');
      const manifest = JSON.parse((await readFile(manifestFile,'utf8')).replace(/^\uFEFF/,''));
      const type = String(manifest?.type).toLowerCase();
      if (type === 'scene' || manifest?.konturScene === true) throw Error('Сцены Wallpaper Engine больше не поддерживаются.');
      const entry = typeof manifest?.file === 'string' ? manifest.file.replaceAll('\\','/').replace(/^\.\//,'') : '';
      if (type !== 'web' || !safeFile(entry) || !/\.html?$/i.test(entry))
        throw Error('Проект должен содержать HTML-обои Wallpaper Engine.');
      const html = await realpath(join(projectRoot,entry));
      if (!html.toLowerCase().startsWith(projectRoot.toLowerCase() + sep) || !(await stat(html)).isFile())
        throw Error('HTML-файл обоев отсутствует.');
      const previewName = typeof manifest.preview === 'string' ? manifest.preview.replaceAll('\\','/').replace(/^\.\//,'') : '';
      const preview = safeFile(previewName) && /\.(png|jpe?g|webp)$/i.test(previewName) &&
        (await stat(join(projectRoot,previewName)).catch(() => null))?.isFile() ? previewName : '';
      const title = typeof manifest.title === 'string' ? manifest.title.trim().slice(0,160) || 'Веб-обои' : 'Веб-обои';
      const id = randomUUID();
      const meta = {title,entry,preview,relative,manifestName:manifestPath.split('/').at(-1)};
      await writeFile(join(stage,'metadata.json'),JSON.stringify(meta));
      await rename(stage, join(library,id));
      return {id,title,preview:!!preview};
    } catch (error) {
      if (error.code || error instanceof SyntaxError) throw Error('Не удалось прочитать файлы веб-проекта.');
      throw error;
    } finally {
      await rm(scratch,{recursive:true,force:true}).catch(() => {});
    }
  }
  async function preview(id) {
    const meta = await record(id);
    if (!meta.preview) throw Error('No preview');
    const path = join(meta.files,meta.relative,meta.preview);
    if ((await stat(path)).size > 8 * 1024 * 1024) throw Error('Preview too large');
    const extension = extname(meta.preview).toLowerCase();
    return {content:await readFile(path), type:extension === '.png' ? 'image/png' : extension === '.webp' ? 'image/webp' : 'image/jpeg'};
  }
  async function list() {
    const directories = await readdir(library,{withFileTypes:true}).catch(() => []);
    return (await Promise.all(directories.filter(item => item.isDirectory() && guid.test(item.name))
      .map(item => record(item.name).then(meta => ({id:meta.id,title:meta.title,preview:!!meta.preview})).catch(() => null)))).filter(Boolean);
  }
  return {extract,record,preview,list};
}
