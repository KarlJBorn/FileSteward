/// FileSteward Consolidate engine — multi-source hash diff.
///
/// Reads a JSON command from stdin:
/// ```json
/// {
///   "command": "consolidate_scan",
///   "primary": "/path/to/primary",
///   "secondaries": ["/path/to/secondary_1", "/path/to/secondary_2"]
/// }
/// ```
///
/// Streams progress events to stdout (NDJSON), then emits a final
/// `consolidate_scan_complete` event with the unique files per secondary.
use hex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// IPC types
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct ConsolidateScanCommand {
    primary: String,
    secondaries: Vec<String>,
}

#[derive(Serialize)]
struct ConsolidateProgressEvent {
    #[serde(rename = "type")]
    event_type: &'static str,
    source: String,
    files_scanned: usize,
}

#[derive(Serialize)]
struct UniqueFile {
    relative_path: String,
    size_bytes: u64,
}

#[derive(Serialize)]
struct SecondaryResult {
    path: String,
    unique_files: Vec<UniqueFile>,
}

#[derive(Serialize)]
struct ConsolidateScanComplete {
    #[serde(rename = "type")]
    event_type: &'static str,
    primary: String,
    secondaries: Vec<SecondaryResult>,
}

#[derive(Serialize)]
struct ConsolidateError {
    #[serde(rename = "type")]
    event_type: &'static str,
    message: String,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn emit<T: Serialize>(value: &T) {
    if let Ok(json) = serde_json::to_string(value) {
        println!("{}", json);
        io::stdout().flush().ok();
    }
}

fn emit_error(message: &str) {
    emit(&ConsolidateError {
        event_type: "consolidate_error",
        message: message.to_string(),
    });
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

/// Walk a directory tree and collect SHA-256 hashes of all files.
/// Returns (hash_set, file_count). Errors on individual files are skipped.
fn collect_hashes(root: &Path) -> HashSet<String> {
    let mut hashes = HashSet::new();
    collect_hashes_dir(root, root, &mut hashes);
    hashes
}

fn collect_hashes_dir(root: &Path, current: &Path, hashes: &mut HashSet<String>) {
    let read_dir = match fs::read_dir(current) {
        Ok(rd) => rd,
        Err(_) => return,
    };
    for entry_result in read_dir {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if metadata.is_dir() {
            collect_hashes_dir(root, &path, hashes);
        } else if metadata.is_file() {
            if let Some(hash) = hash_file(&path) {
                hashes.insert(hash);
            }
        }
    }
}

/// Walk a secondary directory, find files whose hash is not in `primary_hashes`.
/// Emits progress events as it goes.
fn diff_secondary(
    secondary_root: &Path,
    primary_hashes: &HashSet<String>,
) -> Vec<UniqueFile> {
    let mut unique = Vec::new();
    let mut files_scanned = 0usize;
    diff_secondary_dir(
        secondary_root,
        secondary_root,
        primary_hashes,
        &mut unique,
        &mut files_scanned,
        &secondary_root.to_string_lossy().to_string(),
    );
    unique.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    unique
}

fn diff_secondary_dir(
    root: &Path,
    current: &Path,
    primary_hashes: &HashSet<String>,
    unique: &mut Vec<UniqueFile>,
    files_scanned: &mut usize,
    source_label: &str,
) {
    let read_dir = match fs::read_dir(current) {
        Ok(rd) => rd,
        Err(_) => return,
    };
    for entry_result in read_dir {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if metadata.is_dir() {
            diff_secondary_dir(root, &path, primary_hashes, unique, files_scanned, source_label);
        } else if metadata.is_file() {
            *files_scanned += 1;

            // Emit progress every 50 files.
            if *files_scanned % 50 == 0 {
                emit(&ConsolidateProgressEvent {
                    event_type: "consolidate_progress",
                    source: source_label.to_string(),
                    files_scanned: *files_scanned,
                });
            }

            if let Some(hash) = hash_file(&path) {
                if !primary_hashes.contains(&hash) {
                    let relative_path = path
                        .strip_prefix(root)
                        .map(|p| p.to_string_lossy().to_string())
                        .unwrap_or_default();
                    unique.push(UniqueFile {
                        relative_path,
                        size_bytes: metadata.len(),
                    });
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn run(cmd: ConsolidateScanCommand) {
    // Validate primary.
    let primary_path = PathBuf::from(&cmd.primary);
    if !primary_path.is_dir() {
        emit_error(&format!("Primary directory not found: {}", cmd.primary));
        return;
    }

    // Validate secondaries (max 2).
    if cmd.secondaries.is_empty() || cmd.secondaries.len() > 2 {
        emit_error("Consolidate requires 1 or 2 secondary directories.");
        return;
    }
    for sec in &cmd.secondaries {
        if !Path::new(sec).is_dir() {
            emit_error(&format!("Secondary directory not found: {}", sec));
            return;
        }
    }

    // Build primary hash set — walk and hash everything.
    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: cmd.primary.clone(),
        files_scanned: 0,
    });
    let primary_hashes = collect_hashes(&primary_path);

    // Diff each secondary against the primary hash set.
    let mut secondary_results = Vec::new();
    for sec_path_str in &cmd.secondaries {
        let sec_path = PathBuf::from(sec_path_str);
        let unique_files = diff_secondary(&sec_path, &primary_hashes);
        secondary_results.push(SecondaryResult {
            path: sec_path_str.clone(),
            unique_files,
        });
    }

    emit(&ConsolidateScanComplete {
        event_type: "consolidate_scan_complete",
        primary: cmd.primary.clone(),
        secondaries: secondary_results,
    });
}

// ---------------------------------------------------------------------------
// Stdin dispatch — called from main.rs
// ---------------------------------------------------------------------------

pub fn run_from_stdin() {
    let mut input = String::new();
    if io::stdin().read_line(&mut input).is_err() {
        emit_error("Failed to read command from stdin.");
        return;
    }
    match serde_json::from_str::<ConsolidateScanCommand>(&input) {
        Ok(cmd) => run(cmd),
        Err(e) => emit_error(&format!("Failed to parse consolidate command: {}", e)),
    }
}
