mod convention;
mod rationalize;

use hex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// The name of the cache file written next to each scanned folder.
/// Excluded from manifests so it does not appear as an entry.
const CACHE_FILENAME: &str = ".filesteward_manifest.json";

#[derive(Serialize, Deserialize)]
struct ManifestEntry {
    relative_path: String,
    entry_type: String,
    #[serde(default)]
    size_bytes: Option<u64>,
    #[serde(default)]
    sha256: Option<String>,
    #[serde(default)]
    modified_secs: Option<u64>,
}

#[derive(Serialize, Deserialize)]
struct ManifestResult {
    selected_folder: String,
    exists: bool,
    is_directory: bool,
    total_directories: usize,
    total_files: usize,
    entries: Vec<ManifestEntry>,
    #[serde(default)]
    duplicate_groups: Vec<Vec<String>>,
}

#[derive(Serialize)]
struct ProgressEvent {
    #[serde(rename = "type")]
    event_type: &'static str,
    files_scanned: usize,
    total_files: usize,
}

#[derive(Serialize)]
struct CountingCompleteEvent {
    #[serde(rename = "type")]
    event_type: &'static str,
    total_files: usize,
}

fn emit_progress(files_scanned: usize, total_files: usize) {
    let event = ProgressEvent {
        event_type: "progress",
        files_scanned,
        total_files,
    };
    if let Ok(json) = serde_json::to_string(&event) {
        println!("{}", json);
        io::stdout().flush().ok();
    }
}

fn count_files(root: &Path) -> usize {
    let mut count = 0;
    if let Ok(read_dir) = fs::read_dir(root) {
        for entry_result in read_dir {
            if let Ok(entry) = entry_result {
                let path = entry.path();
                if path.file_name().and_then(|n| n.to_str()) == Some(CACHE_FILENAME) {
                    continue;
                }
                if path.is_dir() {
                    count += count_files(&path);
                } else if path.is_file() {
                    count += 1;
                }
            }
        }
    }
    count
}

fn get_modified_secs(metadata: &fs::Metadata) -> Option<u64> {
    metadata
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
}

#[derive(Serialize)]
struct ExtensionStat {
    extension: String,
    count: usize,
    total_bytes: u64,
}

#[derive(Serialize)]
struct InventoryResult {
    selected_folder: String,
    exists: bool,
    is_directory: bool,
    total_files: usize,
    extensions: Vec<ExtensionStat>,
}

fn inventory_walk(root_path: &Path) -> Result<Vec<ExtensionStat>, String> {
    let mut counts: HashMap<String, (usize, u64)> = HashMap::new();
    inventory_walk_dir(root_path, root_path, &mut counts)?;

    let mut stats: Vec<ExtensionStat> = counts
        .into_iter()
        .map(|(ext, (count, total_bytes))| ExtensionStat {
            extension: ext,
            count,
            total_bytes,
        })
        .collect();

    stats.sort_by(|a, b| b.count.cmp(&a.count).then(a.extension.cmp(&b.extension)));
    Ok(stats)
}

fn inventory_walk_dir(
    root_path: &Path,
    current_path: &Path,
    counts: &mut HashMap<String, (usize, u64)>,
) -> Result<(), String> {
    let read_dir = fs::read_dir(current_path).map_err(|e| e.to_string())?;
    for entry_result in read_dir {
        let entry = entry_result.map_err(|e| e.to_string())?;
        let path = entry.path();
        let metadata = entry.metadata().map_err(|e| e.to_string())?;
        if metadata.is_dir() {
            inventory_walk_dir(root_path, &path, counts)?;
        } else if metadata.is_file() {
            let ext = path
                .extension()
                .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
                .unwrap_or_default();
            let entry_ref = counts.entry(ext).or_insert((0, 0));
            entry_ref.0 += 1;
            entry_ref.1 += metadata.len();
        }
    }
    Ok(())
}

fn hash_file(path: &Path) -> Option<String> {
    let mut file = fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Some(hex::encode(hasher.finalize()))
}

fn build_duplicate_groups(entries: &[ManifestEntry]) -> Vec<Vec<String>> {
    let mut by_hash: HashMap<&str, Vec<&str>> = HashMap::new();
    for entry in entries {
        if entry.entry_type == "file" {
            if let Some(hash) = &entry.sha256 {
                by_hash.entry(hash).or_default().push(&entry.relative_path);
            }
        }
    }
    let mut groups: Vec<Vec<String>> = by_hash
        .into_values()
        .filter(|paths| paths.len() >= 2)
        .map(|paths| {
            let mut sorted: Vec<String> = paths.iter().map(|s| s.to_string()).collect();
            sorted.sort();
            sorted
        })
        .collect();
    groups.sort_by(|a, b| a[0].cmp(&b[0]));
    groups
}

// ---------------------------------------------------------------------------
// Persistent manifest cache
// ---------------------------------------------------------------------------

fn cache_path(folder_path: &Path) -> PathBuf {
    folder_path.join(CACHE_FILENAME)
}

/// Load a previously saved manifest from disk. Returns None if the file does
/// not exist or cannot be parsed (e.g. written by an older version).
fn load_cached_manifest(folder_path: &Path) -> Option<ManifestResult> {
    let content = fs::read_to_string(cache_path(folder_path)).ok()?;
    serde_json::from_str(&content).ok()
}

/// Walk the directory collecting only (relative_path, size_bytes, modified_secs)
/// for each file — no hashing. Used to validate the cache cheaply.
/// Returns false if any I/O error occurs; caller treats that as cache-invalid.
fn collect_file_metadata(
    root_path: &Path,
    current_path: &Path,
    result: &mut HashMap<String, (Option<u64>, Option<u64>)>,
) -> bool {
    let read_dir = match fs::read_dir(current_path) {
        Ok(rd) => rd,
        Err(_) => return false,
    };
    for entry_result in read_dir {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => return false,
        };
        let path = entry.path();
        // Skip the cache file itself so it never ends up in comparisons.
        if path.file_name().and_then(|n| n.to_str()) == Some(CACHE_FILENAME) {
            continue;
        }
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => return false,
        };
        if metadata.is_dir() {
            if !collect_file_metadata(root_path, &path, result) {
                return false;
            }
        } else if metadata.is_file() {
            let relative = match path.strip_prefix(root_path) {
                Ok(p) => p.to_string_lossy().to_string(),
                Err(_) => return false,
            };
            result.insert(relative, (Some(metadata.len()), get_modified_secs(&metadata)));
        }
    }
    true
}

/// Returns true if every file in the cache matches the current disk state
/// (same count, same size, same mtime for each file).
fn is_cache_valid(cached: &ManifestResult, root_path: &Path) -> bool {
    let cached_files: HashMap<&str, (Option<u64>, Option<u64>)> = cached
        .entries
        .iter()
        .filter(|e| e.entry_type == "file")
        .map(|e| (e.relative_path.as_str(), (e.size_bytes, e.modified_secs)))
        .collect();

    let mut disk_files: HashMap<String, (Option<u64>, Option<u64>)> = HashMap::new();
    if !collect_file_metadata(root_path, root_path, &mut disk_files) {
        return false;
    }

    if cached_files.len() != disk_files.len() {
        return false;
    }

    for (path, (disk_size, disk_mtime)) in &disk_files {
        match cached_files.get(path.as_str()) {
            None => return false,
            Some((cached_size, cached_mtime)) => {
                if disk_size != cached_size || disk_mtime != cached_mtime {
                    return false;
                }
            }
        }
    }
    true
}

/// Save the manifest next to the scanned folder as CACHE_FILENAME.
/// Writes to a temp file first then renames atomically. Failures are
/// non-fatal — a missing or stale cache just causes a full rescan next time.
fn save_manifest(folder_path: &Path, result: &ManifestResult) {
    let tmp = folder_path.join(".filesteward_manifest.tmp");
    if let Ok(json) = serde_json::to_string(result) {
        if fs::write(&tmp, &json).is_ok() {
            let _ = fs::rename(&tmp, cache_path(folder_path));
        }
    }
}

/// Emit the final result in the appropriate format (streaming NDJSON line or
/// pretty-printed batch JSON).
fn emit_result(streaming: bool, result: ManifestResult) {
    if streaming {
        #[derive(Serialize)]
        struct ResultEvent {
            #[serde(rename = "type")]
            event_type: &'static str,
            #[serde(flatten)]
            result: ManifestResult,
        }
        let event = ResultEvent {
            event_type: "result",
            result,
        };
        match serde_json::to_string(&event) {
            Ok(json) => {
                println!("{}", json);
                io::stdout().flush().ok();
            }
            Err(err) => {
                eprintln!("Failed to serialize JSON: {}", err);
                std::process::exit(1);
            }
        }
    } else {
        match serde_json::to_string_pretty(&result) {
            Ok(json) => println!("{}", json),
            Err(err) => {
                eprintln!("Failed to serialize JSON: {}", err);
                std::process::exit(1);
            }
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: rust_core <folder_path> [--stream-progress] [--force-rescan]");
        eprintln!("       rust_core rationalize <folder_path>");
        std::process::exit(1);
    }

    // Subcommand dispatch — rationalize mode (Iteration 3)
    if args[1] == "rationalize" {
        if args.len() < 3 {
            eprintln!("Usage: rust_core rationalize <folder_path>");
            std::process::exit(1);
        }
        rationalize::run(&args[2]);
        return;
    }

    let folder_path = &args[1];
    let streaming = args.contains(&"--stream-progress".to_string());
    let force_rescan = args.contains(&"--force-rescan".to_string());
    let root_path = Path::new(folder_path);

    if args.iter().any(|a| a == "--inventory-only") {
        let exists = root_path.exists();
        let is_directory = root_path.is_dir();
        let extensions = if exists && is_directory {
            match inventory_walk(root_path) {
                Ok(stats) => stats,
                Err(err) => {
                    eprintln!("Failed to build inventory: {}", err);
                    std::process::exit(1);
                }
            }
        } else {
            Vec::new()
        };
        let total_files: usize = extensions.iter().map(|s| s.count).sum();
        let result = InventoryResult {
            selected_folder: folder_path.to_string(),
            exists,
            is_directory,
            total_files,
            extensions,
        };
        match serde_json::to_string_pretty(&result) {
            Ok(json) => println!("{}", json),
            Err(err) => {
                eprintln!("Failed to serialize JSON: {}", err);
                std::process::exit(1);
            }
        }
        return;
    }

    // Parse --include-extensions .jpg,.pdf,... into a filter list.
    let include_extensions: Option<Vec<String>> = args
        .iter()
        .skip_while(|a| *a != "--include-extensions")
        .nth(1)
        .map(|val| {
            val.split(',')
                .map(|e| {
                    let t = e.trim().to_lowercase();
                    if t.starts_with('.') {
                        t
                    } else {
                        format!(".{}", t)
                    }
                })
                .filter(|e| !e.is_empty() && e != ".")
                .collect()
        });

    let exists = root_path.exists();
    let is_directory = root_path.is_dir();

    // Cache hit path: load and validate the saved manifest. If valid, emit it
    // directly without hashing anything. Skip on --force-rescan.
    if !force_rescan && exists && is_directory {
        if let Some(cached) = load_cached_manifest(root_path) {
            if is_cache_valid(&cached, root_path) {
                emit_result(streaming, cached);
                return;
            }
        }
    }

    // Full scan path.
    let mut entries: Vec<ManifestEntry> = Vec::new();
    let mut total_directories: usize = 0;
    let mut total_files: usize = 0;
    let mut files_scanned: usize = 0;

    // Pre-pass: count files and emit counting_complete so Flutter can show
    // a determinate progress bar from the start.
    let stream_total = if streaming && exists && is_directory {
        let total = count_files(root_path);
        let event = CountingCompleteEvent {
            event_type: "counting_complete",
            total_files: total,
        };
        if let Ok(json) = serde_json::to_string(&event) {
            println!("{}", json);
            io::stdout().flush().ok();
        }
        total
    } else {
        0
    };

    if exists && is_directory {
        if let Err(err) = walk_directory(
            root_path,
            root_path,
            &mut entries,
            &mut total_directories,
            &mut total_files,
            streaming,
            &mut files_scanned,
            stream_total,
            include_extensions.as_deref(),
        ) {
            eprintln!("Failed to build manifest: {}", err);
            std::process::exit(1);
        }
    }

    entries.sort_by(|a, b| {
        a.relative_path
            .to_lowercase()
            .cmp(&b.relative_path.to_lowercase())
    });

    let duplicate_groups = build_duplicate_groups(&entries);

    let result = ManifestResult {
        selected_folder: folder_path.to_string(),
        exists,
        is_directory,
        total_directories,
        total_files,
        duplicate_groups,
        entries,
    };

    // Persist the manifest so the next scan can skip hashing if nothing changed.
    // Write failures are non-fatal (e.g. read-only volumes).
    if exists && is_directory {
        save_manifest(root_path, &result);
    }

    emit_result(streaming, result);
}

fn walk_directory(
    root_path: &Path,
    current_path: &Path,
    entries: &mut Vec<ManifestEntry>,
    total_directories: &mut usize,
    total_files: &mut usize,
    streaming: bool,
    files_scanned: &mut usize,
    stream_total: usize,
    include_extensions: Option<&[String]>,
) -> Result<(), String> {
    let read_dir = fs::read_dir(current_path).map_err(|err| err.to_string())?;

    for entry_result in read_dir {
        let entry = entry_result.map_err(|err| err.to_string())?;
        let entry_path: PathBuf = entry.path();
        let metadata = entry.metadata().map_err(|err| err.to_string())?;

        // Skip the cache file so it never appears as a manifest entry.
        if entry_path.file_name().and_then(|n| n.to_str()) == Some(CACHE_FILENAME) {
            continue;
        }

        let relative_path = entry_path
            .strip_prefix(root_path)
            .map_err(|err| err.to_string())?
            .to_string_lossy()
            .to_string();

        let modified_secs = get_modified_secs(&metadata);

        if metadata.is_dir() {
            *total_directories += 1;

            entries.push(ManifestEntry {
                relative_path,
                entry_type: "directory".to_string(),
                size_bytes: None,
                sha256: None,
                modified_secs,
            });

            walk_directory(
                root_path,
                &entry_path,
                entries,
                total_directories,
                total_files,
                streaming,
                files_scanned,
                stream_total,
                include_extensions,
            )?;
        } else if metadata.is_file() {
            // If a scope filter is set, skip files whose extension is not included.
            if let Some(filter) = include_extensions {
                let ext = entry_path
                    .extension()
                    .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
                    .unwrap_or_default();
                if !filter.iter().any(|f| f == &ext) {
                    continue;
                }
            }

            *total_files += 1;
            let sha256 = hash_file(&entry_path);

            if streaming {
                *files_scanned += 1;
                emit_progress(*files_scanned, stream_total);
            }

            entries.push(ManifestEntry {
                relative_path,
                entry_type: "file".to_string(),
                size_bytes: Some(metadata.len()),
                sha256,
                modified_secs,
            });
        } else {
            entries.push(ManifestEntry {
                relative_path,
                entry_type: "other".to_string(),
                size_bytes: None,
                sha256: None,
                modified_secs,
            });
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn write_file(dir: &Path, name: &str, content: &[u8]) -> PathBuf {
        let path = dir.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut f = fs::File::create(&path).unwrap();
        f.write_all(content).unwrap();
        path
    }

    fn make_entry(
        relative_path: &str,
        entry_type: &str,
        size_bytes: Option<u64>,
        sha256: Option<&str>,
    ) -> ManifestEntry {
        ManifestEntry {
            relative_path: relative_path.into(),
            entry_type: entry_type.into(),
            size_bytes,
            sha256: sha256.map(|s| s.into()),
            modified_secs: None,
        }
    }

    // --- inventory_walk ---

    #[test]
    fn test_inventory_walk_counts_by_extension() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.jpg", b"img");
        write_file(dir.path(), "b.jpg", b"img2");
        write_file(dir.path(), "c.pdf", b"doc");

        let stats = inventory_walk(dir.path()).unwrap();
        let jpg = stats.iter().find(|s| s.extension == ".jpg").unwrap();
        let pdf = stats.iter().find(|s| s.extension == ".pdf").unwrap();
        assert_eq!(jpg.count, 2);
        assert_eq!(pdf.count, 1);
    }

    #[test]
    fn test_inventory_walk_accumulates_sizes() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.txt", b"hello");
        write_file(dir.path(), "b.txt", b"world!");

        let stats = inventory_walk(dir.path()).unwrap();
        let txt = stats.iter().find(|s| s.extension == ".txt").unwrap();
        assert_eq!(txt.total_bytes, 11); // 5 + 6
    }

    #[test]
    fn test_inventory_walk_is_recursive() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "top.jpg", b"t");
        write_file(dir.path(), "sub/nested.jpg", b"n");

        let stats = inventory_walk(dir.path()).unwrap();
        let jpg = stats.iter().find(|s| s.extension == ".jpg").unwrap();
        assert_eq!(jpg.count, 2);
    }

    #[test]
    fn test_inventory_walk_files_without_extension() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "README", b"no ext");

        let stats = inventory_walk(dir.path()).unwrap();
        let no_ext = stats.iter().find(|s| s.extension.is_empty()).unwrap();
        assert_eq!(no_ext.count, 1);
    }

    // --- hash_file ---

    #[test]
    fn test_hash_file_is_consistent() {
        let dir = TempDir::new().unwrap();
        let path = write_file(dir.path(), "test.txt", b"hello world");
        assert_eq!(hash_file(&path), hash_file(&path));
    }

    #[test]
    fn test_hash_file_length_is_64_chars() {
        let dir = TempDir::new().unwrap();
        let path = write_file(dir.path(), "test.txt", b"hello");
        assert_eq!(hash_file(&path).unwrap().len(), 64);
    }

    #[test]
    fn test_hash_file_differs_for_different_content() {
        let dir = TempDir::new().unwrap();
        let a = write_file(dir.path(), "a.txt", b"hello");
        let b = write_file(dir.path(), "b.txt", b"world");
        assert_ne!(hash_file(&a), hash_file(&b));
    }

    #[test]
    fn test_hash_file_matches_for_same_content() {
        let dir = TempDir::new().unwrap();
        let a = write_file(dir.path(), "a.txt", b"duplicate");
        let b = write_file(dir.path(), "b.txt", b"duplicate");
        assert_eq!(hash_file(&a), hash_file(&b));
    }

    #[test]
    fn test_hash_file_empty_file() {
        // SHA-256 of zero bytes is a well-defined constant — verify we produce it.
        let dir = TempDir::new().unwrap();
        let path = write_file(dir.path(), "empty.txt", b"");
        let hash = hash_file(&path).unwrap();
        assert_eq!(hash.len(), 64);
        assert_eq!(
            hash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn test_hash_file_large_file_exercises_buffer_loop() {
        // Write 200 KB — forces the 65536-byte read buffer to loop multiple times.
        let dir = TempDir::new().unwrap();
        let content = vec![0xABu8; 200 * 1024];
        let a = write_file(dir.path(), "a.bin", &content);
        let b = write_file(dir.path(), "b.bin", &content);
        let hash_a = hash_file(&a).unwrap();
        let hash_b = hash_file(&b).unwrap();
        assert_eq!(hash_a.len(), 64);
        assert_eq!(hash_a, hash_b);
    }

    #[cfg(unix)]
    #[test]
    fn test_hash_file_returns_none_for_unreadable_file() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let path = write_file(dir.path(), "secret.txt", b"secret");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
        let result = hash_file(&path);
        // Restore permissions so TempDir can clean up.
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(result.is_none(), "Expected None for unreadable file");
    }

    // --- get_modified_secs ---

    #[test]
    fn test_modified_secs_is_some_for_real_file() {
        let dir = TempDir::new().unwrap();
        let path = write_file(dir.path(), "ts.txt", b"hello");
        let metadata = fs::metadata(&path).unwrap();
        let secs = get_modified_secs(&metadata);
        assert!(secs.is_some(), "Expected Some timestamp for a real file");
        // Sanity check: timestamp should be after 2020-01-01 (Unix ts 1577836800).
        assert!(secs.unwrap() > 1_577_836_800);
    }

    // --- count_files ---

    #[test]
    fn test_count_files_counts_only_files() {
        let dir = TempDir::new().unwrap();
        let subdir = dir.path().join("subdir");
        fs::create_dir(&subdir).unwrap();
        write_file(dir.path(), "a.txt", b"a");
        write_file(dir.path(), "b.txt", b"b");
        write_file(&subdir, "c.txt", b"c");
        assert_eq!(count_files(dir.path()), 3);
    }

    #[test]
    fn test_count_files_empty_dir() {
        let dir = TempDir::new().unwrap();
        assert_eq!(count_files(dir.path()), 0);
    }

    // --- build_duplicate_groups ---

    #[test]
    fn test_duplicate_groups_empty_input() {
        assert!(build_duplicate_groups(&[]).is_empty());
    }

    #[test]
    fn test_duplicate_groups_no_duplicates() {
        let entries = vec![
            make_entry("a.txt", "file", Some(5), Some("aaaa")),
            make_entry("b.txt", "file", Some(5), Some("bbbb")),
        ];
        assert!(build_duplicate_groups(&entries).is_empty());
    }

    #[test]
    fn test_duplicate_groups_detects_pair() {
        let entries = vec![
            make_entry("a.txt", "file", Some(5), Some("same")),
            make_entry("b.txt", "file", Some(5), Some("same")),
            make_entry("c.txt", "file", Some(5), Some("different")),
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0], vec!["a.txt", "b.txt"]);
    }

    #[test]
    fn test_duplicate_groups_detects_three_way_group() {
        let entries = vec![
            make_entry("a.txt", "file", Some(5), Some("same")),
            make_entry("b.txt", "file", Some(5), Some("same")),
            make_entry("c.txt", "file", Some(5), Some("same")),
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0], vec!["a.txt", "b.txt", "c.txt"]);
    }

    #[test]
    fn test_duplicate_groups_two_independent_groups() {
        let entries = vec![
            make_entry("a.txt", "file", Some(5), Some("hash_x")),
            make_entry("b.txt", "file", Some(5), Some("hash_x")),
            make_entry("c.txt", "file", Some(5), Some("hash_y")),
            make_entry("d.txt", "file", Some(5), Some("hash_y")),
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0], vec!["a.txt", "b.txt"]);
        assert_eq!(groups[1], vec!["c.txt", "d.txt"]);
    }

    #[test]
    fn test_duplicate_groups_ignores_directories() {
        let entries = vec![
            make_entry("dir_a", "directory", None, None),
            make_entry("a.txt", "file", Some(5), Some("same")),
            make_entry("b.txt", "file", Some(5), Some("same")),
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0], vec!["a.txt", "b.txt"]);
    }

    #[test]
    fn test_duplicate_groups_skips_file_with_no_hash() {
        // A file whose hash is None (e.g. unreadable) must not crash or pollute groups.
        let entries = vec![
            make_entry("a.txt", "file", Some(5), Some("same")),
            make_entry("b.txt", "file", Some(5), None),
        ];
        assert!(build_duplicate_groups(&entries).is_empty());
    }

    // --- walker + corpus integration ---

    #[test]
    fn test_walker_detects_duplicates_in_corpus() {
        // Fixture: alpha.txt, beta.txt, subdir/gamma.txt all contain
        // "duplicate file content"; delta.txt is unique.
        // Expect exactly one group containing those three paths.
        let corpus_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("test_corpus/duplicates");

        let mut entries = Vec::new();
        let mut total_dirs = 0;
        let mut total_files = 0;
        let mut files_scanned = 0;

        walk_directory(
            &corpus_path,
            &corpus_path,
            &mut entries,
            &mut total_dirs,
            &mut total_files,
            false,
            &mut files_scanned,
            0,
            None,
        )
        .unwrap();

        assert_eq!(total_files, 4, "Fixture should have exactly 4 files");
        assert_eq!(total_dirs, 1, "Fixture should have exactly 1 subdirectory");

        // Every file entry should carry a modified_secs timestamp.
        let file_entries: Vec<&ManifestEntry> = entries
            .iter()
            .filter(|e| e.entry_type == "file")
            .collect();
        for entry in &file_entries {
            assert!(
                entry.modified_secs.is_some(),
                "Expected modified_secs on file entry '{}'",
                entry.relative_path
            );
        }

        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 1, "Expected exactly one duplicate group");

        let mut group = groups[0].clone();
        group.sort();
        assert_eq!(
            group,
            vec!["alpha.txt", "beta.txt", "subdir/gamma.txt"],
            "Group members don't match expected fixture paths"
        );

        // Verify the unique file is absent from all groups.
        let grouped_paths: Vec<&str> = groups.iter().flatten().map(String::as_str).collect();
        assert!(
            !grouped_paths.contains(&"delta.txt"),
            "delta.txt should not appear in any duplicate group"
        );
    }

    // --- persistent manifest cache ---

    fn build_test_result(dir: &Path) -> ManifestResult {
        let mut entries = Vec::new();
        let mut total_dirs = 0;
        let mut total_files = 0;
        let mut files_scanned = 0;
        walk_directory(
            dir, dir, &mut entries, &mut total_dirs, &mut total_files,
            false, &mut files_scanned, 0, None,
        )
        .unwrap();
        let duplicate_groups = build_duplicate_groups(&entries);
        ManifestResult {
            selected_folder: dir.to_string_lossy().to_string(),
            exists: true,
            is_directory: true,
            total_directories: total_dirs,
            total_files: total_files,
            entries,
            duplicate_groups,
        }
    }

    #[test]
    fn test_save_and_load_manifest_round_trips() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.txt", b"hello");
        let result = build_test_result(dir.path());

        save_manifest(dir.path(), &result);

        let loaded = load_cached_manifest(dir.path())
            .expect("Cache file should exist after save");
        assert_eq!(loaded.total_files, result.total_files);
        assert_eq!(loaded.entries.len(), result.entries.len());
    }

    #[test]
    fn test_cache_valid_when_files_unchanged() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.txt", b"hello");
        write_file(dir.path(), "b.txt", b"world");
        let result = build_test_result(dir.path());
        save_manifest(dir.path(), &result);

        let cached = load_cached_manifest(dir.path()).unwrap();
        assert!(
            is_cache_valid(&cached, dir.path()),
            "Cache should be valid when nothing has changed"
        );
    }

    #[test]
    fn test_cache_invalid_when_file_content_changes() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.txt", b"original");
        let result = build_test_result(dir.path());
        save_manifest(dir.path(), &result);

        // Overwrite with different content (changes size and mtime).
        write_file(dir.path(), "a.txt", b"completely different content here");

        let cached = load_cached_manifest(dir.path()).unwrap();
        assert!(
            !is_cache_valid(&cached, dir.path()),
            "Cache should be invalid after file content changes"
        );
    }

    #[test]
    fn test_cache_invalid_when_file_added() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.txt", b"hello");
        let result = build_test_result(dir.path());
        save_manifest(dir.path(), &result);

        write_file(dir.path(), "b.txt", b"new file");

        let cached = load_cached_manifest(dir.path()).unwrap();
        assert!(
            !is_cache_valid(&cached, dir.path()),
            "Cache should be invalid after a file is added"
        );
    }

    #[test]
    fn test_cache_invalid_when_file_removed() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.txt", b"hello");
        write_file(dir.path(), "b.txt", b"world");
        let result = build_test_result(dir.path());
        save_manifest(dir.path(), &result);

        fs::remove_file(dir.path().join("b.txt")).unwrap();

        let cached = load_cached_manifest(dir.path()).unwrap();
        assert!(
            !is_cache_valid(&cached, dir.path()),
            "Cache should be invalid after a file is removed"
        );
    }

    #[test]
    fn test_cache_file_excluded_from_manifest_entries() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.txt", b"hello");
        let result = build_test_result(dir.path());
        save_manifest(dir.path(), &result);

        // Re-scan — the cache file must not appear in entries.
        let result2 = build_test_result(dir.path());
        let cache_in_entries = result2
            .entries
            .iter()
            .any(|e| e.relative_path == CACHE_FILENAME);
        assert!(
            !cache_in_entries,
            ".filesteward_manifest.json must not appear as a manifest entry"
        );
    }

    #[test]
    fn test_load_returns_none_for_missing_cache() {
        let dir = TempDir::new().unwrap();
        assert!(
            load_cached_manifest(dir.path()).is_none(),
            "Should return None when no cache file exists"
        );
    }

    // --- walk_directory extension filter ---

    #[test]
    fn test_walk_with_extension_filter_only_includes_matching_files() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "photo.jpg", b"img");
        write_file(dir.path(), "document.pdf", b"doc");
        write_file(dir.path(), "notes.txt", b"txt");

        let filter = vec![".jpg".to_string(), ".pdf".to_string()];
        let mut entries = Vec::new();
        let mut total_dirs = 0;
        let mut total_files = 0;
        let mut files_scanned = 0;

        walk_directory(
            dir.path(), dir.path(), &mut entries, &mut total_dirs,
            &mut total_files, false, &mut files_scanned, 0, Some(&filter),
        )
        .unwrap();

        assert_eq!(total_files, 2);
        let names: Vec<&str> = entries.iter().map(|e| e.relative_path.as_str()).collect();
        assert!(names.iter().any(|n| n.ends_with("photo.jpg")));
        assert!(names.iter().any(|n| n.ends_with("document.pdf")));
        assert!(!names.iter().any(|n| n.ends_with("notes.txt")));
    }

    #[test]
    fn test_walk_with_no_filter_includes_all_files() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "a.jpg", b"img");
        write_file(dir.path(), "b.txt", b"txt");

        let mut entries = Vec::new();
        let mut total_dirs = 0;
        let mut total_files = 0;
        let mut files_scanned = 0;

        walk_directory(
            dir.path(), dir.path(), &mut entries, &mut total_dirs,
            &mut total_files, false, &mut files_scanned, 0, None,
        )
        .unwrap();

        assert_eq!(total_files, 2);
    }

    #[test]
    fn test_walk_filter_always_includes_directories() {
        let dir = TempDir::new().unwrap();
        write_file(dir.path(), "sub/photo.jpg", b"img");
        write_file(dir.path(), "sub/notes.txt", b"txt");

        let filter = vec![".jpg".to_string()];
        let mut entries = Vec::new();
        let mut total_dirs = 0;
        let mut total_files = 0;
        let mut files_scanned = 0;

        walk_directory(
            dir.path(), dir.path(), &mut entries, &mut total_dirs,
            &mut total_files, false, &mut files_scanned, 0, Some(&filter),
        )
        .unwrap();

        assert_eq!(total_dirs, 1, "Directory should still be counted");
        assert_eq!(total_files, 1, "Only .jpg file should be counted");
        let has_dir = entries.iter().any(|e| e.entry_type == "directory");
        assert!(has_dir, "Directory entry should be present regardless of filter");
    }
}
