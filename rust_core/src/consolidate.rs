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
use hex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
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
}

#[derive(Serialize, Deserialize, Clone)]
struct SessionRecord {
    id: String,
    created: String,
    target: String,
    primary: String,
    status: String,
    secondaries: Vec<SecondaryRecord>,
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
    ConsolidateScan(ScanCmd),
    ConsolidateBuild(BuildCmd),
    ConsolidateFinalize(FinalizeCmd),
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

fn diff_secondary(secondary_root: &Path, primary_hashes: &HashSet<String>) -> Vec<UniqueFile> {
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
    let primary_hashes = collect_hashes(&primary_path);

    let mut secondary_results = Vec::new();
    for sec_path_str in &cmd.secondaries {
        let sec_path = PathBuf::from(sec_path_str);
        let unique_files = diff_secondary(&sec_path, &primary_hashes);
        secondary_results.push(SecondaryResult {
            path: sec_path_str.clone(),
            unique_files,
        });
    }

    // Write session to registry as in_progress.
    let mut registry = load_registry();
    upsert_session(&mut registry, SessionRecord {
        id: session_id.clone(),
        created,
        target: cmd.target.clone().unwrap_or_default(),
        primary: cmd.primary.clone(),
        status: "in_progress".to_string(),
        secondaries: vec![],
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
        Err(e) => emit_error(&format!("Failed to parse consolidate command: {}", e)),
    }
}
