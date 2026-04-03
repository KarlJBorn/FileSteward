/// FileSteward Consolidate engine — multi-source hash diff + session registry.
///
/// Reads a JSON command from stdin. Supported commands:
///
/// **consolidate_scan** — walk sources, diff secondaries against primary:
/// ```json
/// {
///   "command": "consolidate_scan",
///   "primary": "/path/to/primary",
///   "secondaries": ["/path/to/secondary_1", "/path/to/secondary_2"]
/// }
/// ```
///
/// **consolidate_build** — copy approved unique files into the target:
/// ```json
/// {
///   "command": "consolidate_build",
///   "session_id": "2026-04-01T15-00-00",
///   "target": "/path/to/target",
///   "fold_ins": [
///     { "source_root": "/path/to/secondary_1", "relative_path": "photos/beach.jpg" }
///   ]
/// }
/// ```
///
/// **consolidate_finalize** — mark a session as finalized in the registry:
/// ```json
/// { "command": "consolidate_finalize", "session_id": "2026-04-01T15-00-00" }
/// ```
use crate::rationalize::penalty_score;
use hex;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Registry types (~/.filesteward/sessions.json)
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "snake_case")]
#[allow(dead_code)]
pub enum SessionStatus {
    InProgress,
    Complete,
    Finalized,
}

#[derive(Serialize, Deserialize, Clone)]
struct SecondaryRecord {
    path: String,
    analyzed: String,
    status: String,
    files_folded_in: usize,
    files_skipped: usize,
    skipped: Vec<String>,
    /// Unique files found during the scan phase — persisted so the scan
    /// can be resumed without rehashing.
    #[serde(default)]
    unique_files: Vec<UniqueFile>,
}

#[derive(Serialize, Deserialize, Clone)]
struct SessionRecord {
    id: String,
    created: String,
    target: String,
    primary: String,
    status: String,
    secondaries: Vec<SecondaryRecord>,
    /// All content hashes approved into the target so far (across all folded folders).
    /// Persisted so fold scans for subsequent folders can diff against this set.
    #[serde(default)]
    accumulated_hashes: Vec<String>,
    /// Folders in processing order (Iteration 6 peer model).
    #[serde(default)]
    folders: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct Registry {
    sessions: Vec<SessionRecord>,
}

// ---------------------------------------------------------------------------
// IPC command types
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum ConsolidateCommand {
    // v1 commands (primary/secondary model)
    ConsolidateScan(ScanCmd),
    ConsolidateBuild(BuildCmd),
    ConsolidateFinalize(FinalizeCmd),
    ConsolidateLoad(LoadCmd),
    // v2 commands (peer-folder model)
    ConsolidateRationalizeScan(RationalizeScanCmd),
    ConsolidateFoldScan(FoldScanCmd),
    ConsolidateAccumulate(AccumulateCmd),
    ConsolidateV2Build(V2BuildCmd),
}

#[derive(Deserialize)]
struct LoadCmd {
    primary: String,
    secondaries: Vec<String>,
}

#[derive(Deserialize)]
struct ScanCmd {
    primary: String,
    secondaries: Vec<String>,
    /// Optional: if provided, a new session is created/updated in the registry.
    session_id: Option<String>,
    target: Option<String>,
}

#[derive(Deserialize)]
struct FoldIn {
    source_root: String,
    relative_path: String,
    /// Relative paths within the secondary that were skipped by the user.
    #[serde(default)]
    skipped: Vec<String>,
}

#[derive(Deserialize)]
struct BuildCmd {
    session_id: String,
    target: String,
    fold_ins: Vec<FoldIn>,
}

#[derive(Deserialize)]
struct FinalizeCmd {
    session_id: String,
}

// v2 command structs --------------------------------------------------------

/// Scan one folder for internal duplicates. Returns duplicate groups (ranked)
/// plus the list of non-duplicate files.
#[derive(Deserialize)]
struct RationalizeScanCmd {
    session_id: String,
    folder: String,
}

/// Compare one folder against the session's accumulated hashes. Returns files
/// whose content is not yet in the accumulated base.
#[derive(Deserialize)]
struct FoldScanCmd {
    session_id: String,
    folder: String,
}

/// Record approved hashes into the session's accumulated set after user review.
#[derive(Deserialize)]
struct AccumulateCmd {
    session_id: String,
    /// Content hashes of all files the user approved to keep/fold in.
    approved_hashes: Vec<String>,
    /// Folders list — full ordered list of folders for this session.
    #[serde(default)]
    folders: Vec<String>,
    /// Target directory path.
    #[serde(default)]
    target: String,
}

/// Build the target by copying all approved files from all folders.
#[derive(Deserialize)]
struct V2FolderBuild {
    folder: String,
    /// Relative paths to copy from this folder.
    relative_paths: Vec<String>,
}

#[derive(Deserialize)]
struct V2BuildCmd {
    session_id: String,
    target: String,
    folders: Vec<V2FolderBuild>,
}

// ---------------------------------------------------------------------------
// IPC output types
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ConsolidateProgressEvent {
    #[serde(rename = "type")]
    event_type: &'static str,
    source: String,
    files_scanned: usize,
}

#[derive(Serialize, Deserialize, Clone)]
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
    session_id: String,
    primary: String,
    secondaries: Vec<SecondaryResult>,
}

#[derive(Serialize)]
struct ConsolidateBuildComplete {
    #[serde(rename = "type")]
    event_type: &'static str,
    session_id: String,
    target: String,
    files_copied: usize,
}

#[derive(Serialize)]
struct ConsolidateFinalizeComplete {
    #[serde(rename = "type")]
    event_type: &'static str,
    session_id: String,
}

#[derive(Serialize)]
struct ConsolidateLoadNotFound {
    #[serde(rename = "type")]
    event_type: &'static str,
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

fn now_iso() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Format as a sortable ISO-like string.
    let dt = secs_to_iso(secs);
    dt
}

fn secs_to_iso(secs: u64) -> String {
    // Simple UTC formatter — avoids pulling in chrono.
    let s = secs % 60;
    let m = (secs / 60) % 60;
    let h = (secs / 3600) % 24;
    let days = secs / 86400;
    // Days since 1970-01-01 → year/month/day
    let (y, mo, d) = days_to_ymd(days);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, h, m, s)
}

fn days_to_ymd(mut days: u64) -> (u64, u64, u64) {
    let mut y = 1970u64;
    loop {
        let dy = if is_leap(y) { 366 } else { 365 };
        if days < dy {
            break;
        }
        days -= dy;
        y += 1;
    }
    let leap = is_leap(y);
    let months = [31u64, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut mo = 1u64;
    for dm in &months {
        if days < *dm {
            break;
        }
        days -= dm;
        mo += 1;
    }
    (y, mo, days + 1)
}

fn is_leap(y: u64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn session_id_from_iso(iso: &str) -> String {
    iso.replace(':', "-").replace('T', "T").trim_end_matches('Z').to_string()
}

// ---------------------------------------------------------------------------
// Registry read/write
// ---------------------------------------------------------------------------

fn registry_path() -> Option<PathBuf> {
    // Allow tests (and CI) to redirect the registry to a temp location.
    if let Ok(p) = std::env::var("FILESTEWARD_REGISTRY_PATH") {
        return Some(PathBuf::from(p));
    }
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join(".filesteward").join("sessions.json"))
}

fn load_registry() -> Registry {
    registry_path()
        .and_then(|p| fs::read_to_string(&p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Registry { sessions: vec![] })
}

fn save_registry(registry: &Registry) {
    let Some(path) = registry_path() else { return };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("tmp");
    if let Ok(json) = serde_json::to_string_pretty(registry) {
        if fs::write(&tmp, &json).is_ok() {
            let _ = fs::rename(&tmp, &path);
        }
    }
}

fn upsert_session(registry: &mut Registry, record: SessionRecord) {
    if let Some(existing) = registry.sessions.iter_mut().find(|s| s.id == record.id) {
        *existing = record;
    } else {
        registry.sessions.push(record);
    }
}

// ---------------------------------------------------------------------------
// Hashing + directory walk
// ---------------------------------------------------------------------------

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

/// Directory names that are always skipped during walking.
const SKIP_DIRS: &[&str] = &[
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
    ".TemporaryItems",
    ".DocumentRevisions-V100",
    ".PKInstallSandboxManager",
    "__MACOSX",
    ".git",
    ".svn",
    "node_modules",
];

/// File names that are always skipped.
const SKIP_FILES: &[&str] = &[
    ".DS_Store",
    ".localized",
    "Thumbs.db",
    "desktop.ini",
    ".dropbox",
    ".dropbox.cache",
];

fn should_skip_dir(name: &str) -> bool {
    // Skip hidden dirs (starting with '.') and known system dirs.
    name.starts_with('.') || SKIP_DIRS.contains(&name)
}

fn should_skip_file(name: &str) -> bool {
    SKIP_FILES.contains(&name)
}

/// Walk a directory tree and return all non-system file paths.
fn walk_files(root: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    walk_files_dir(root, &mut paths);
    paths
}

fn walk_files_dir(current: &Path, out: &mut Vec<PathBuf>) {
    let read_dir = match fs::read_dir(current) {
        Ok(rd) => rd,
        Err(_) => return,
    };
    for entry_result in read_dir {
        let entry = match entry_result {
            Ok(e) => e,
            Err(_) => continue,
        };
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if metadata.is_dir() {
            if !should_skip_dir(&name_str) {
                walk_files_dir(&path, out);
            }
        } else if metadata.is_file() {
            if !should_skip_file(&name_str) {
                out.push(path);
            }
        }
    }
}

/// Build a hash set of all SHA-256 digests in [root], hashing in parallel.
/// Returns (hash_set, size_set, file_count).
fn collect_hashes(root: &Path) -> (HashSet<String>, HashSet<u64>, usize) {
    let files = walk_files(root);
    let count = files.len();
    let (hashes, sizes): (HashSet<String>, HashSet<u64>) = files
        .par_iter()
        .map(|p| {
            let size = fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            let hash = hash_file(p);
            (hash, size)
        })
        .fold(
            || (HashSet::new(), HashSet::new()),
            |(mut hs, mut ss), (hash, size)| {
                if let Some(h) = hash {
                    hs.insert(h);
                }
                ss.insert(size);
                (hs, ss)
            },
        )
        .reduce(
            || (HashSet::new(), HashSet::new()),
            |(mut hs1, mut ss1), (hs2, ss2)| {
                hs1.extend(hs2);
                ss1.extend(ss2);
                (hs1, ss1)
            },
        );
    (hashes, sizes, count)
}

/// Diff [secondary_root] against [primary_hashes], returning files whose
/// content is not present in the primary. Hashing runs in parallel;
/// progress events are emitted on the calling thread every 500 files.
/// Files whose size is not present in [primary_sizes] are immediately
/// classified as unique without hashing.
fn diff_secondary(
    secondary_root: &Path,
    primary_hashes: &HashSet<String>,
    primary_sizes: &HashSet<u64>,
    source_label: &str,
) -> Vec<UniqueFile> {
    let files = walk_files(secondary_root);
    let total = files.len();
    let counter = AtomicUsize::new(0);

    // Emit a starting progress event so the UI sees movement immediately.
    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: source_label.to_string(),
        files_scanned: 0,
    });

    let unique: Vec<UniqueFile> = files
        .par_iter()
        .filter_map(|path| {
            let n = counter.fetch_add(1, Ordering::Relaxed) + 1;
            // Emit progress on rough multiples of 5% of total (min 50 files).
            let interval = (total / 20).max(50);
            if n % interval == 0 {
                emit(&ConsolidateProgressEvent {
                    event_type: "consolidate_progress",
                    source: source_label.to_string(),
                    files_scanned: n,
                });
            }
            let metadata = fs::metadata(path).ok()?;
            let size = metadata.len();
            let relative_path = path
                .strip_prefix(secondary_root)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default();
            // Size pre-filter: if no primary file has this size, no primary
            // file can have matching content — skip hashing entirely.
            if !primary_sizes.contains(&size) {
                return Some(UniqueFile { relative_path, size_bytes: size });
            }
            // Size matches at least one primary file — must hash to be sure.
            let hash = hash_file(path)?;
            if primary_hashes.contains(&hash) {
                return None;
            }
            Some(UniqueFile {
                relative_path,
                size_bytes: size,
            })
        })
        .collect();

    let mut sorted = unique;
    sorted.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    sorted
}

// ---------------------------------------------------------------------------
// v2 output event types
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ConsolidateDuplicateGroup {
    paths: Vec<String>,
    suggested_keep: String,
    reasons: Vec<String>,
    ambiguous: bool,
    size_bytes: u64,
}

#[derive(Serialize)]
struct ConsolidateRationalizeScanComplete {
    #[serde(rename = "type")]
    event_type: &'static str,
    session_id: String,
    folder: String,
    duplicate_groups: Vec<ConsolidateDuplicateGroup>,
    clean_files: Vec<UniqueFile>,
    system_files_skipped: usize,
}

#[derive(Serialize)]
struct ConsolidateFoldScanComplete {
    #[serde(rename = "type")]
    event_type: &'static str,
    session_id: String,
    folder: String,
    unique_files: Vec<UniqueFile>,
}

#[derive(Serialize)]
struct ConsolidateAccumulateComplete {
    #[serde(rename = "type")]
    event_type: &'static str,
    session_id: String,
    accumulated_count: usize,
}

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

fn handle_scan(cmd: ScanCmd) {
    let primary_path = PathBuf::from(&cmd.primary);
    if !primary_path.is_dir() {
        emit_error(&format!("Primary directory not found: {}", cmd.primary));
        return;
    }
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

    // Assign session id — use provided or generate from current time.
    let created = now_iso();
    let session_id = cmd.session_id
        .clone()
        .unwrap_or_else(|| session_id_from_iso(&created));

    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: cmd.primary.clone(),
        files_scanned: 0,
    });
    let (primary_hashes, primary_sizes, primary_count) = collect_hashes(&primary_path);
    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: cmd.primary.clone(),
        files_scanned: primary_count,
    });

    let mut secondary_results = Vec::new();
    for sec_path_str in &cmd.secondaries {
        let sec_path = PathBuf::from(sec_path_str);
        let unique_files = diff_secondary(&sec_path, &primary_hashes, &primary_sizes, sec_path_str);
        secondary_results.push(SecondaryResult {
            path: sec_path_str.clone(),
            unique_files,
        });
    }

    // Write session to registry, including unique file lists so the scan
    // can be resumed without rehashing.
    let analyzed = now_iso();
    let registry_secondaries: Vec<SecondaryRecord> = secondary_results
        .iter()
        .map(|s| SecondaryRecord {
            path: s.path.clone(),
            analyzed: analyzed.clone(),
            status: "scanned".to_string(),
            files_folded_in: 0,
            files_skipped: 0,
            skipped: vec![],
            unique_files: s.unique_files.iter().map(|f| UniqueFile {
                relative_path: f.relative_path.clone(),
                size_bytes: f.size_bytes,
            }).collect(),
        })
        .collect();

    let mut registry = load_registry();
    upsert_session(&mut registry, SessionRecord {
        id: session_id.clone(),
        created,
        target: cmd.target.clone().unwrap_or_default(),
        primary: cmd.primary.clone(),
        status: "in_progress".to_string(),
        secondaries: registry_secondaries,
        accumulated_hashes: vec![],
        folders: vec![],
    });
    save_registry(&registry);

    emit(&ConsolidateScanComplete {
        event_type: "consolidate_scan_complete",
        session_id,
        primary: cmd.primary.clone(),
        secondaries: secondary_results,
    });
}

fn handle_build(cmd: BuildCmd) {
    let target = PathBuf::from(&cmd.target);

    // Create target directory if needed.
    if let Err(e) = fs::create_dir_all(&target) {
        emit_error(&format!("Failed to create target directory: {}", e));
        return;
    }

    let mut files_copied = 0usize;
    let mut secondary_records: Vec<SecondaryRecord> = Vec::new();

    // Group fold_ins by source_root to build per-secondary records.
    let mut by_source: std::collections::HashMap<String, (Vec<String>, Vec<String>)> =
        std::collections::HashMap::new();

    for fi in &cmd.fold_ins {
        let entry = by_source.entry(fi.source_root.clone()).or_default();
        entry.0.push(fi.relative_path.clone());
        for s in &fi.skipped {
            entry.1.push(s.clone());
        }
    }

    for (source_root, (approved, skipped)) in &by_source {
        let source_path = PathBuf::from(source_root);
        let mut folded = 0usize;

        for rel in approved {
            let src = source_path.join(rel);
            let dst = target.join(rel);

            if let Some(parent) = dst.parent() {
                let _ = fs::create_dir_all(parent);
            }
            match fs::copy(&src, &dst) {
                Ok(_) => {
                    folded += 1;
                    files_copied += 1;
                    if files_copied % 10 == 0 {
                        emit(&ConsolidateProgressEvent {
                            event_type: "consolidate_progress",
                            source: cmd.target.clone(),
                            files_scanned: files_copied,
                        });
                    }
                }
                Err(e) => {
                    emit_error(&format!("Failed to copy {}: {}", rel, e));
                }
            }
        }

        let analyzed = now_iso();
        secondary_records.push(SecondaryRecord {
            path: source_root.clone(),
            analyzed,
            status: "complete".to_string(),
            files_folded_in: folded,
            files_skipped: skipped.len(),
            skipped: skipped.clone(),
            unique_files: vec![], // scan results already persisted; not needed post-build
        });
    }

    // Update registry — mark session complete with secondary records.
    let mut registry = load_registry();
    if let Some(session) = registry.sessions.iter_mut().find(|s| s.id == cmd.session_id) {
        session.target = cmd.target.clone();
        session.status = "complete".to_string();
        session.secondaries = secondary_records;
    }
    save_registry(&registry);

    emit(&ConsolidateBuildComplete {
        event_type: "consolidate_build_complete",
        session_id: cmd.session_id.clone(),
        target: cmd.target.clone(),
        files_copied,
    });
}

fn handle_finalize(cmd: FinalizeCmd) {
    let mut registry = load_registry();
    if let Some(session) = registry.sessions.iter_mut().find(|s| s.id == cmd.session_id) {
        session.status = "finalized".to_string();
    }
    save_registry(&registry);

    emit(&ConsolidateFinalizeComplete {
        event_type: "consolidate_finalize_complete",
        session_id: cmd.session_id,
    });
}

fn handle_load(cmd: LoadCmd) {
    let registry = load_registry();

    // Find the most recent in_progress or complete session matching
    // this primary + secondary set.
    let mut secondaries_sorted = cmd.secondaries.clone();
    secondaries_sorted.sort();

    let session = registry.sessions.iter()
        .filter(|s| {
            if s.primary != cmd.primary { return false; }
            if s.status == "finalized" { return false; }
            // Secondary paths must match exactly.
            let mut reg_paths: Vec<String> =
                s.secondaries.iter().map(|r| r.path.clone()).collect();
            reg_paths.sort();
            reg_paths == secondaries_sorted
        })
        // Take the most recently created session.
        .max_by(|a, b| a.created.cmp(&b.created));

    match session {
        None => {
            emit(&ConsolidateLoadNotFound {
                event_type: "consolidate_load_not_found",
            });
        }
        Some(s) => {
            let secondaries: Vec<SecondaryResult> = s.secondaries.iter().map(|r| {
                SecondaryResult {
                    path: r.path.clone(),
                    unique_files: r.unique_files.iter().map(|f| UniqueFile {
                        relative_path: f.relative_path.clone(),
                        size_bytes: f.size_bytes,
                    }).collect(),
                }
            }).collect();
            emit(&ConsolidateScanComplete {
                event_type: "consolidate_scan_complete",
                session_id: s.id.clone(),
                primary: s.primary.clone(),
                secondaries,
            });
        }
    }
}

// ---------------------------------------------------------------------------
// v2 handlers
// ---------------------------------------------------------------------------

/// Hash every file in [root] in parallel, returning (relative_path, hash, size).
fn hash_all_files(root: &Path) -> Vec<(String, Option<String>, u64)> {
    let files = walk_files(root);
    files
        .par_iter()
        .map(|p| {
            let size = fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            let hash = hash_file(p);
            let rel = p.strip_prefix(root)
                .map(|r| r.to_string_lossy().to_string())
                .unwrap_or_default();
            (rel, hash, size)
        })
        .collect()
}

fn handle_rationalize_scan(cmd: RationalizeScanCmd) {
    let folder_path = PathBuf::from(&cmd.folder);
    if !folder_path.is_dir() {
        emit_error(&format!("Folder not found: {}", cmd.folder));
        return;
    }

    // Generate or reuse session id.
    let session_id = if cmd.session_id.is_empty() {
        session_id_from_iso(&now_iso())
    } else {
        cmd.session_id.clone()
    };

    // Emit starting progress.
    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: cmd.folder.clone(),
        files_scanned: 0,
    });

    let all_files = hash_all_files(&folder_path);
    let total = all_files.len();
    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: cmd.folder.clone(),
        files_scanned: total,
    });

    // Group by hash to find duplicates.
    let mut by_hash: HashMap<String, Vec<(String, u64)>> = HashMap::new();
    for (rel, hash_opt, size) in &all_files {
        if let Some(h) = hash_opt {
            by_hash.entry(h.clone()).or_default().push((rel.clone(), *size));
        }
    }

    let mut duplicate_groups: Vec<ConsolidateDuplicateGroup> = Vec::new();
    let mut dupe_paths: HashSet<String> = HashSet::new();

    for (_hash, entries) in &by_hash {
        if entries.len() < 2 {
            continue;
        }

        // Score each path; pick the lowest (best) scoring one.
        let scored: Vec<(u32, Vec<String>, &String, u64)> = entries
            .iter()
            .map(|(rel, sz)| {
                let (score, reasons) = penalty_score(rel);
                (score, reasons, rel, *sz)
            })
            .collect();

        let min_score = scored.iter().map(|(s, _, _, _)| *s).min().unwrap_or(0);
        let candidates: Vec<_> = scored.iter().filter(|(s, _, _, _)| *s == min_score).collect();
        let (suggested_keep, reasons, ambiguous) = if candidates.len() == 1 {
            let (_, _reasons, rel, _) = candidates[0];
            // Produce positive reasons from the losers' reasons.
            let positive_reasons: Vec<String> = scored
                .iter()
                .filter(|(_, _, r, _)| *r != candidates[0].2)
                .flat_map(|(_, rs, _, _)| rs.iter().cloned())
                .collect();
            ((*rel).clone(), positive_reasons, false)
        } else {
            // Still tied — pick alphabetically as a stable fallback, mark ambiguous.
            let mut alpha_candidates: Vec<&String> = candidates.iter().map(|(_, _, r, _)| *r).collect();
            alpha_candidates.sort();
            (alpha_candidates[0].clone(), vec![], true)
        };

        let size_bytes = entries[0].1;
        let paths: Vec<String> = entries.iter().map(|(r, _)| r.clone()).collect();
        for p in &paths {
            dupe_paths.insert(p.clone());
        }
        duplicate_groups.push(ConsolidateDuplicateGroup {
            paths,
            suggested_keep,
            reasons,
            ambiguous,
            size_bytes,
        });
    }

    // Files not in any duplicate group.
    let clean_files: Vec<UniqueFile> = all_files
        .iter()
        .filter(|(rel, hash_opt, _)| !dupe_paths.contains(rel) && hash_opt.is_some())
        .map(|(rel, _, size)| UniqueFile {
            relative_path: rel.clone(),
            size_bytes: *size,
        })
        .collect();

    // Save session to registry.
    let mut registry = load_registry();
    let existing = registry.sessions.iter().find(|s| s.id == session_id).cloned();
    let mut folders = existing.as_ref().map(|s| s.folders.clone()).unwrap_or_default();
    if !folders.contains(&cmd.folder) {
        folders.push(cmd.folder.clone());
    }
    let accumulated_hashes = existing.as_ref().map(|s| s.accumulated_hashes.clone()).unwrap_or_default();
    upsert_session(&mut registry, SessionRecord {
        id: session_id.clone(),
        created: existing.map(|s| s.created).unwrap_or_else(|| now_iso()),
        target: String::new(),
        primary: String::new(),
        status: "in_progress".to_string(),
        secondaries: vec![],
        accumulated_hashes,
        folders,
    });
    save_registry(&registry);

    emit(&ConsolidateRationalizeScanComplete {
        event_type: "consolidate_rationalize_scan_complete",
        session_id,
        folder: cmd.folder.clone(),
        duplicate_groups,
        clean_files,
        system_files_skipped: 0,
    });
}

fn handle_fold_scan(cmd: FoldScanCmd) {
    let folder_path = PathBuf::from(&cmd.folder);
    if !folder_path.is_dir() {
        emit_error(&format!("Folder not found: {}", cmd.folder));
        return;
    }

    // Load accumulated hashes from session.
    let registry = load_registry();
    let accumulated: HashSet<String> = registry.sessions
        .iter()
        .find(|s| s.id == cmd.session_id)
        .map(|s| s.accumulated_hashes.iter().cloned().collect())
        .unwrap_or_default();

    // Also build a size set for quick filtering.
    let accumulated_sizes: HashSet<u64> = HashSet::new(); // no size prefilter needed without primary sizes

    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: cmd.folder.clone(),
        files_scanned: 0,
    });

    let all_files = hash_all_files(&folder_path);

    emit(&ConsolidateProgressEvent {
        event_type: "consolidate_progress",
        source: cmd.folder.clone(),
        files_scanned: all_files.len(),
    });

    let _ = accumulated_sizes; // suppress unused warning

    let unique_files: Vec<UniqueFile> = all_files
        .into_iter()
        .filter(|(_, hash_opt, _)| {
            hash_opt.as_ref().map(|h| !accumulated.contains(h)).unwrap_or(false)
        })
        .map(|(rel, _, size)| UniqueFile { relative_path: rel, size_bytes: size })
        .collect();

    emit(&ConsolidateFoldScanComplete {
        event_type: "consolidate_fold_scan_complete",
        session_id: cmd.session_id,
        folder: cmd.folder,
        unique_files,
    });
}

fn handle_accumulate(cmd: AccumulateCmd) {
    let mut registry = load_registry();
    let session_opt = registry.sessions.iter_mut().find(|s| s.id == cmd.session_id);

    let mut accumulated: Vec<String>;
    let mut folders: Vec<String>;
    let mut target: String;
    let id: String;
    let created: String;
    let status: String;

    if let Some(session) = session_opt {
        accumulated = session.accumulated_hashes.clone();
        folders = session.folders.clone();
        target = session.target.clone();
        id = session.id.clone();
        created = session.created.clone();
        status = session.status.clone();
    } else {
        // New session.
        let now = now_iso();
        id = session_id_from_iso(&now);
        created = now;
        accumulated = vec![];
        folders = vec![];
        target = String::new();
        status = "in_progress".to_string();
    }

    // Add approved hashes, deduplicating.
    let existing_set: HashSet<String> = accumulated.iter().cloned().collect();
    for h in cmd.approved_hashes {
        if !existing_set.contains(&h) {
            accumulated.push(h);
        }
    }

    if !cmd.folders.is_empty() {
        folders = cmd.folders;
    }
    if !cmd.target.is_empty() {
        target = cmd.target;
    }

    let accumulated_count = accumulated.len();

    upsert_session(&mut registry, SessionRecord {
        id: id.clone(),
        created,
        target,
        primary: String::new(),
        status,
        secondaries: vec![],
        accumulated_hashes: accumulated,
        folders,
    });
    save_registry(&registry);

    emit(&ConsolidateAccumulateComplete {
        event_type: "consolidate_accumulate_complete",
        session_id: id,
        accumulated_count,
    });
}

fn handle_v2_build(cmd: V2BuildCmd) {
    let target = PathBuf::from(&cmd.target);
    if let Err(e) = fs::create_dir_all(&target) {
        emit_error(&format!("Failed to create target directory: {}", e));
        return;
    }

    let mut files_copied = 0usize;

    for folder_build in &cmd.folders {
        let folder_path = PathBuf::from(&folder_build.folder);
        for rel in &folder_build.relative_paths {
            let src = folder_path.join(rel);
            let dst = target.join(rel);
            if let Some(parent) = dst.parent() {
                let _ = fs::create_dir_all(parent);
            }
            match fs::copy(&src, &dst) {
                Ok(_) => {
                    files_copied += 1;
                    if files_copied % 10 == 0 {
                        emit(&ConsolidateProgressEvent {
                            event_type: "consolidate_progress",
                            source: cmd.target.clone(),
                            files_scanned: files_copied,
                        });
                    }
                }
                Err(e) => {
                    emit_error(&format!("Failed to copy {}: {}", rel, e));
                }
            }
        }
    }

    // Update session in registry.
    let mut registry = load_registry();
    if let Some(session) = registry.sessions.iter_mut().find(|s| s.id == cmd.session_id) {
        session.status = "complete".to_string();
        session.target = cmd.target.clone();
    }
    save_registry(&registry);

    emit(&ConsolidateBuildComplete {
        event_type: "consolidate_build_complete",
        session_id: cmd.session_id.clone(),
        target: cmd.target.clone(),
        files_copied,
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
    match serde_json::from_str::<ConsolidateCommand>(&input) {
        Ok(ConsolidateCommand::ConsolidateScan(cmd)) => handle_scan(cmd),
        Ok(ConsolidateCommand::ConsolidateBuild(cmd)) => handle_build(cmd),
        Ok(ConsolidateCommand::ConsolidateFinalize(cmd)) => handle_finalize(cmd),
        Ok(ConsolidateCommand::ConsolidateLoad(cmd)) => handle_load(cmd),
        Ok(ConsolidateCommand::ConsolidateRationalizeScan(cmd)) => handle_rationalize_scan(cmd),
        Ok(ConsolidateCommand::ConsolidateFoldScan(cmd)) => handle_fold_scan(cmd),
        Ok(ConsolidateCommand::ConsolidateAccumulate(cmd)) => handle_accumulate(cmd),
        Ok(ConsolidateCommand::ConsolidateV2Build(cmd)) => handle_v2_build(cmd),
        Err(e) => emit_error(&format!("Failed to parse consolidate command: {}", e)),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn write_file(dir: &Path, rel: &str, content: &[u8]) {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let mut f = fs::File::create(path).unwrap();
        f.write_all(content).unwrap();
    }

    #[test]
    fn test_handle_rationalize_scan_detects_duplicates() {
        let dir = TempDir::new().unwrap();
        let root = dir.path();

        // Two identical files (same content = same hash = duplicate).
        let content = b"hello duplicate world";
        write_file(root, "alpha/file.txt", content);
        write_file(root, "beta/file.txt", content);

        // One unique file.
        write_file(root, "gamma/unique.txt", b"unique content here");

        // Use a temp registry path so we don't pollute the real one.
        let reg_dir = TempDir::new().unwrap();
        let reg_path = reg_dir.path().join("sessions.json");
        // SAFETY: test binary is single-threaded for env mutation purposes.
        unsafe { std::env::set_var("FILESTEWARD_REGISTRY_PATH", &reg_path) };

        let cmd = RationalizeScanCmd {
            session_id: String::new(),
            folder: root.to_string_lossy().to_string(),
        };

        // Capture stdout to parse the output event.
        // Since emit() writes to real stdout, we test indirectly through
        // the internal logic.
        let all_files = hash_all_files(root);
        assert_eq!(all_files.len(), 3);

        let mut by_hash: HashMap<String, Vec<(String, u64)>> = HashMap::new();
        for (rel, hash_opt, size) in &all_files {
            if let Some(h) = hash_opt {
                by_hash.entry(h.clone()).or_default().push((rel.clone(), *size));
            }
        }

        let dupe_groups: Vec<_> = by_hash.values().filter(|g| g.len() >= 2).collect();
        assert_eq!(dupe_groups.len(), 1, "Expected exactly 1 duplicate group");

        let group = &dupe_groups[0];
        assert_eq!(group.len(), 2, "Duplicate group should have 2 entries");

        // Both paths should be the two file.txt copies.
        let paths: Vec<&str> = group.iter().map(|(r, _)| r.as_str()).collect();
        assert!(paths.iter().any(|p| p.contains("alpha")));
        assert!(paths.iter().any(|p| p.contains("beta")));

        // Verify penalty_score picks one of them as suggested_keep.
        let (score_a, _) = penalty_score("alpha/file.txt");
        let (score_b, _) = penalty_score("beta/file.txt");
        // Both should have equal scores (same depth, no copy artifacts).
        assert_eq!(score_a, score_b);

        // Run the full handler to verify it saves a session.
        handle_rationalize_scan(cmd);
        let registry = load_registry();
        assert!(
            !registry.sessions.is_empty(),
            "A session should have been saved"
        );
        let session = &registry.sessions[0];
        assert_eq!(session.status, "in_progress");

        // SAFETY: test binary is single-threaded for env mutation purposes.
        unsafe { std::env::remove_var("FILESTEWARD_REGISTRY_PATH") };
    }
}
