use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::env;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use tempfile::Builder;
use uuid::Uuid;

const MIB: u64 = 1024 * 1024;
const MAX_ARCHIVE: u64 = 64 * MIB;
const MAX_EXPANDED: u64 = 192 * MIB;
const MAX_FILES: usize = 2500;
const READ_ERROR: ImportError = ImportError("Не удалось прочитать файлы веб-проекта.");
const SCENE_ERROR: ImportError = ImportError("Сцены Wallpaper Engine больше не поддерживаются.");
const INVALID_FILE: ImportError = ImportError("Некорректный файл проекта.");

struct ImportError(&'static str);

impl From<io::Error> for ImportError {
    fn from(_: io::Error) -> Self {
        READ_ERROR
    }
}

impl From<serde_json::Error> for ImportError {
    fn from(_: serde_json::Error) -> Self {
        READ_ERROR
    }
}

type ImportResult<T> = Result<T, ImportError>;

#[derive(Serialize)]
pub struct ProjectSummary {
    pub id: String,
    pub title: String,
    pub preview: bool,
}

pub struct Project {
    pub entry: String,
    pub relative: String,
    pub manifest_name: String,
    pub files: PathBuf,
    pub directory: PathBuf,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProjectMetadata {
    title: String,
    entry: String,
    #[serde(default)]
    preview: String,
    #[serde(default)]
    relative: String,
    #[serde(default = "default_manifest_name")]
    manifest_name: String,
}

fn default_manifest_name() -> String {
    "project.json".to_owned()
}

pub struct WebLibrary {
    directory: PathBuf,
}

impl WebLibrary {
    pub fn new(root: &Path) -> Self {
        Self {
            directory: root.join("runtime").join("web-wallpapers"),
        }
    }

    pub fn import(
        &self,
        body: &mut dyn Read,
        length: Option<u64>,
        format: &str,
    ) -> Result<ProjectSummary, String> {
        self.import_project(body, length, format)
            .map_err(|error| error.0.to_owned())
    }

    pub fn record(&self, id: &str) -> Result<Project, String> {
        let (directory, metadata) = self.metadata(id).map_err(|error| error.0.to_owned())?;
        let files = directory.join("files");
        let result = Project {
            files,
            directory,
            entry: metadata.entry,
            relative: metadata.relative,
            manifest_name: metadata.manifest_name,
        };
        result
            .validate_paths()
            .map_err(|error| error.0.to_owned())?;
        Ok(result)
    }

    pub fn preview(&self, id: &str) -> Result<(Vec<u8>, &'static str), String> {
        self.read_preview(id).map_err(|error| error.0.to_owned())
    }

    pub fn list(&self) -> Vec<ProjectSummary> {
        fs::read_dir(&self.directory)
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .filter_map(|entry| {
                if !entry.file_type().ok()?.is_dir() {
                    return None;
                }
                let id = entry.file_name().into_string().ok()?;
                let (_, metadata) = self.metadata(&id).ok()?;
                Some(ProjectSummary {
                    id,
                    title: metadata.title,
                    preview: !metadata.preview.is_empty(),
                })
            })
            .collect()
    }

    fn metadata(&self, id: &str) -> ImportResult<(PathBuf, ProjectMetadata)> {
        if !valid_project_id(id) {
            return Err(ImportError("Некорректный ID веб-обоев."));
        }
        let directory = self.directory.join(id);
        let directory_real = directory.canonicalize()?;
        let library_real = self.directory.canonicalize()?;
        if directory_real.parent() != Some(library_real.as_path()) {
            return Err(READ_ERROR);
        }
        let bytes = read_limited(&directory_real.join("metadata.json"), MIB)?;
        let metadata: Value = serde_json::from_slice(&bytes)?;
        if metadata.get("scene").and_then(Value::as_bool) == Some(true) {
            return Err(SCENE_ERROR);
        }
        let mut metadata: ProjectMetadata = serde_json::from_value(metadata)?;
        if metadata.manifest_name.is_empty() {
            metadata.manifest_name = default_manifest_name();
        }
        let relative = metadata.relative.trim_end_matches('/');
        if !is_html(&metadata.entry)
            || !relative.is_empty() && !safe_file(relative)
            || !metadata.relative.is_empty() && relative.is_empty()
            || !metadata.preview.is_empty() && preview_mime(&metadata.preview).is_none()
            || !metadata.manifest_name.eq_ignore_ascii_case("project.json")
        {
            return Err(READ_ERROR);
        }
        Ok((directory, metadata))
    }

    fn read_preview(&self, id: &str) -> ImportResult<(Vec<u8>, &'static str)> {
        let (directory, metadata) = self.metadata(id)?;
        let mime = preview_mime(&metadata.preview).ok_or(ImportError("No preview"))?;
        let files = project_files(&directory)?;
        let path = files
            .join(metadata.relative)
            .join(metadata.preview)
            .canonicalize()?;
        if !path.starts_with(&files) || !path.is_file() {
            return Err(READ_ERROR);
        }
        Ok((read_limited(&path, 8 * MIB)?, mime))
    }

    fn import_project(
        &self,
        body: &mut dyn Read,
        length: Option<u64>,
        format: &str,
    ) -> ImportResult<ProjectSummary> {
        let limit = match format {
            "folder" => MAX_EXPANDED + MIB,
            "rar" | "zip" => MAX_ARCHIVE,
            _ => return Err(ImportError("Выбери RAR, ZIP или папку проекта.")),
        };
        let length = length
            .filter(|length| (8..=limit).contains(length))
            .ok_or(ImportError("Проект слишком большой или пустой."))?;

        fs::create_dir_all(&self.directory)?;
        let scratch = Builder::new()
            .prefix(".import-")
            .tempdir_in(&self.directory)?;
        let input = scratch.path().join(format!("input.{format}"));
        let copied = io::copy(&mut body.take(length + 1), &mut File::create_new(&input)?)?;
        if copied != length {
            return Err(ImportError("Проект передан не полностью."));
        }

        let stage = scratch.path().join("project");
        let target = stage.join("files");
        fs::create_dir_all(&target)?;
        let names = if format == "folder" {
            unpack_folder(&input, &target, length)?
        } else {
            unpack_archive(&input, &target, format)?
        };
        let metadata = read_manifest(&target, &names)?;
        let id = Uuid::new_v4().to_string();
        fs::write(stage.join("metadata.json"), serde_json::to_vec(&metadata)?)?;
        fs::rename(&stage, self.directory.join(&id))?;
        Ok(ProjectSummary {
            id,
            title: metadata.title,
            preview: !metadata.preview.is_empty(),
        })
    }
}

pub fn valid_project_id(id: &str) -> bool {
    id.len() == 36
        && id
            .bytes()
            .all(|byte| matches!(byte, b'a'..=b'f' | b'0'..=b'9' | b'-'))
}

fn project_files(directory: &Path) -> ImportResult<PathBuf> {
    let files = directory.join("files").canonicalize()?;
    if files.parent() != Some(directory.canonicalize()?.as_path()) {
        return Err(READ_ERROR);
    }
    Ok(files)
}

impl Project {
    fn validate_paths(&self) -> ImportResult<()> {
        let files = project_files(&self.directory)?;
        let root = files.join(&self.relative).canonicalize()?;
        let entry = root.join(&self.entry).canonicalize()?;
        if !root.starts_with(&files) || !entry.starts_with(&root) || !entry.is_file() {
            return Err(READ_ERROR);
        }
        Ok(())
    }
}

fn safe_file(path: &str) -> bool {
    !path.contains(|character: char| {
        character <= '\u{1f}' || matches!(character, '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*')
    }) && path.split('/').all(|part| {
        if part.is_empty() || part.ends_with(['.', ' ']) {
            return false;
        }
        let stem = part.split('.').next().unwrap_or_default().trim_end();
        let name = stem.to_ascii_lowercase();
        !matches!(
            name.as_str(),
            "con" | "prn" | "aux" | "nul" | "conin$" | "conout$"
        ) && !name
            .strip_prefix("com")
            .or_else(|| name.strip_prefix("lpt"))
            .is_some_and(|number| {
                matches!(
                    number,
                    "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                )
            })
    })
}

fn is_html(entry: &str) -> bool {
    safe_file(entry)
        && Path::new(entry)
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| {
                extension.eq_ignore_ascii_case("htm") || extension.eq_ignore_ascii_case("html")
            })
}

fn preview_mime(path: &str) -> Option<&'static str> {
    if !safe_file(path) {
        return None;
    }
    let extension = Path::new(path).extension()?.to_str()?.to_ascii_lowercase();
    match extension.as_str() {
        "png" => Some("image/png"),
        "webp" => Some("image/webp"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        _ => None,
    }
}

fn read_limited(path: &Path, limit: u64) -> ImportResult<Vec<u8>> {
    let mut bytes = Vec::new();
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(READ_ERROR);
    }
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(READ_ERROR);
    }
    Ok(bytes)
}

fn unpack_folder(input: &Path, target: &Path, length: u64) -> ImportResult<Vec<String>> {
    let mut input = File::open(input)?;
    let mut header = [0; 4];
    input
        .read_exact(&mut header)
        .map_err(|_| ImportError("Нет каталога файлов проекта."))?;
    let size = u64::from(u32::from_le_bytes(header));
    if size == 0 || size > MIB || size + 4 > length {
        return Err(ImportError("Недопустимый каталог файлов проекта."));
    }
    let mut table = vec![0; size as usize];
    input
        .read_exact(&mut table)
        .map_err(|_| ImportError("Каталог файлов оборван."))?;
    let table: Value = serde_json::from_slice(&table)?;
    let entries = table
        .as_array()
        .filter(|entries| !entries.is_empty() && entries.len() <= MAX_FILES)
        .ok_or(ImportError("Недопустимое число файлов проекта."))?;

    let mut seen = HashSet::new();
    let mut names = Vec::with_capacity(entries.len());
    let mut remaining = length - size - 4;
    for entry in entries {
        let name = entry
            .get("name")
            .and_then(Value::as_str)
            .ok_or(INVALID_FILE)?;
        let size = entry.get("size").and_then(file_size).ok_or(INVALID_FILE)?;
        if !safe_file(name) || !seen.insert(name.to_lowercase()) || size > remaining {
            return Err(INVALID_FILE);
        }
        let output = target.join(name);
        fs::create_dir_all(output.parent().ok_or(INVALID_FILE)?)?;
        let mut output = File::create_new(output)?;
        let copied = io::copy(&mut (&mut input).take(size), &mut output)?;
        if copied != size {
            return Err(ImportError(
                "Размер папки проекта не совпадает с каталогом.",
            ));
        }
        remaining -= size;
        names.push(name.to_owned());
    }
    if remaining != 0 {
        return Err(ImportError(
            "Размер папки проекта не совпадает с каталогом.",
        ));
    }
    Ok(names)
}

fn file_size(size: &Value) -> Option<u64> {
    size.as_u64().or_else(|| {
        let value = size.as_f64()?;
        (value.fract() == 0.0 && (0.0..=(MAX_EXPANDED + MIB) as f64).contains(&value))
            .then_some(value as u64)
    })
}

fn unpack_archive(input: &Path, target: &Path, format: &str) -> ImportResult<Vec<String>> {
    let signature = if format == "rar" {
        &b"Rar!\x1a\x07"[..]
    } else {
        &b"PK\x03\x04"[..]
    };
    let mut header = [0; 6];
    File::open(input)?.read_exact(&mut header[..signature.len()])?;
    if !header.starts_with(signature) {
        return Err(ImportError("Формат архива не совпадает с расширением."));
    }
    let names = tar("-tf", input, None)?;
    let details = tar("-tvf", input, None)?;
    let names: Vec<_> = names.lines().collect();
    let details: Vec<_> = details.lines().collect();
    if names.len() != details.len() || names.len() > MAX_FILES {
        return Err(ImportError("В архиве слишком много файлов."));
    }
    let mut seen = HashSet::new();
    let mut expanded = 0_u64;
    for (&name, detail) in names.iter().zip(details) {
        let path = name.strip_suffix('/').unwrap_or(name);
        let size = if detail.starts_with(['d', '-']) {
            detail
                .split_whitespace()
                .nth(4)
                .and_then(|size| size.parse().ok())
        } else {
            None
        };
        let Some(size) = size.filter(|_| safe_file(path) && seen.insert(path.to_lowercase()))
        else {
            return Err(ImportError(
                "В архиве есть недопустимый путь, ссылка или повторяющееся имя.",
            ));
        };
        expanded = expanded.saturating_add(size);
        if expanded > MAX_EXPANDED {
            return Err(ImportError(
                "Объём файлов после распаковки слишком большой.",
            ));
        }
    }
    tar("-xf", input, Some(target))?;
    Ok(names.into_iter().map(str::to_owned).collect())
}

fn tar(operation: &str, input: &Path, target: Option<&Path>) -> ImportResult<String> {
    let mut command = Command::new(tar_binary());
    command.arg(operation).arg(input);
    if let Some(target) = target {
        command
            .arg("-C")
            .arg(target)
            .args(["--no-same-owner", "--no-same-permissions"]);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let output = child.stdout.take().ok_or(READ_ERROR)?;
    let reader = thread::spawn(move || {
        let mut bytes = Vec::new();
        output.take(MIB + 1).read_to_end(&mut bytes)?;
        Ok::<_, io::Error>(bytes)
    });
    let deadline = Instant::now() + Duration::from_secs(15);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let output = reader.join().map_err(|_| READ_ERROR)??;
    if !status.is_some_and(|status| status.success()) || output.len() as u64 > MIB {
        return Err(READ_ERROR);
    }
    Ok(String::from_utf8_lossy(&output).into_owned())
}

fn tar_binary() -> PathBuf {
    if cfg!(windows) {
        env::var_os("SystemRoot").map_or_else(
            || PathBuf::from("tar.exe"),
            |root| PathBuf::from(root).join("System32").join("tar.exe"),
        )
    } else {
        PathBuf::from("tar")
    }
}

fn normalize_path(value: Option<&Value>) -> String {
    let name = value
        .and_then(Value::as_str)
        .unwrap_or_default()
        .replace('\\', "/");
    match name.strip_prefix("./") {
        Some(stripped) => stripped.to_owned(),
        None => name,
    }
}

fn read_manifest(target: &Path, names: &[String]) -> ImportResult<ProjectMetadata> {
    let manifest_path = names
        .iter()
        .filter(|name| {
            name.rsplit('/')
                .next()
                .is_some_and(|file| file.eq_ignore_ascii_case("project.json"))
        })
        .min_by_key(|name| name.bytes().filter(|byte| *byte == b'/').count())
        .ok_or(ImportError("В проекте нет project.json."))?;
    let (relative, manifest_name) = manifest_path
        .rsplit_once('/')
        .map_or(("", manifest_path.as_str()), |(directory, name)| {
            (directory, name)
        });
    let target = target.canonicalize()?;
    let project_root = target.join(relative).canonicalize()?;
    if !project_root.starts_with(&target) {
        return Err(ImportError("Недопустимая папка проекта."));
    }
    let manifest_file = project_root.join(manifest_name);
    if manifest_file.metadata()?.len() > MIB {
        return Err(ImportError("project.json слишком большой."));
    }
    let bytes = read_limited(&manifest_file, MIB)?;
    let manifest: Value =
        serde_json::from_slice(bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes))?;
    let project_type = manifest
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if project_type.eq_ignore_ascii_case("scene")
        || manifest.get("konturScene").and_then(Value::as_bool) == Some(true)
    {
        return Err(SCENE_ERROR);
    }
    let entry = normalize_path(manifest.get("file"));
    if !project_type.eq_ignore_ascii_case("web") || !is_html(&entry) {
        return Err(ImportError(
            "Проект должен содержать HTML-обои Wallpaper Engine.",
        ));
    }
    let html = project_root.join(&entry).canonicalize()?;
    if !html.starts_with(&project_root) || !html.is_file() {
        return Err(ImportError("HTML-файл обоев отсутствует."));
    }

    let mut preview = normalize_path(manifest.get("preview"));
    if preview_mime(&preview).is_none() || !project_root.join(&preview).is_file() {
        preview.clear();
    }
    let title: String = manifest
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .unwrap_or("Веб-обои")
        .chars()
        .take(160)
        .collect();
    Ok(ProjectMetadata {
        title,
        entry,
        preview,
        relative: manifest_path[..manifest_path.len() - manifest_name.len()].to_owned(),
        manifest_name: manifest_name.to_owned(),
    })
}
