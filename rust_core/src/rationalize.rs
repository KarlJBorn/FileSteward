/// Directory rationalization engine — Iteration 3+.
///
/// Scans a folder tree, generates structural findings (empty folders,
/// naming inconsistencies, misplaced files, excessive nesting), detects
/// duplicate files by SHA-256 hash, then reads an execution plan from stdin
/// and applies the approved actions.
///
/// All output is newline-delimited JSON to stdout. All filesystem operations
/// (rename, move, quarantine) are performed here — Flutter never touches
/// the filesystem directly.

use crate::convention::{classify_convention, dominant_convention, suggest_rename, NamingConvention};
use hex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::io::{self, BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Files treated as system metadata — excluded from real file counts.
/// `.gitkeep` is a git convention for tracking otherwise-empty directories.
const METADATA_FILES: &[&str] = &[".DS_Store", ".localized", "Thumbs.db", ".gitkeep"];

/// Folder depth threshold. Folders deeper than this are flagged.
const NESTING_DEPTH_THRESHOLD: usize = 5;

/// Folder names that are OS-reserved or have well-known conventional meaning
/// and must never be proposed for rename. Exact match, case-sensitive.
const RESERVED_FOLDER_NAMES: &[&str] = &[
    // Generic OS / build conventions
    "TEMP", "TMP", "CACHE", "BACKUP", "RESTORE", "CONFIG",
    "BIN", "LIB", "SRC", "LOG", "LOGS", "DIST", "BUILD", "OUT",
    // macOS system directories
    ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd",
    // Windows shell / profile folders (named system folders — #57)
    "Application Data", "Local Settings", "My Documents", "My Music",
    "My Pictures", "My Videos", "My Recent Documents", "Recent",
    "NetHood", "PrintHood", "SendTo", "Start Menu", "Templates",
    "Cookies", "History", "Temporary Internet Files", "Quick Launch",
    "Desktop", "Favorites", "Fonts", "Identities",
];

/// Regex pattern for Windows COM/OLE GUID-named folders:
/// {8hex-4hex-4hex-4hex-12hex}. These are categorically not user data
/// and are skipped entirely during scan (Option A from issue #57).
fn is_guid_folder(name: &str) -> bool {
    if name.len() != 38 {
        return false;
    }
    let b = name.as_bytes();
    b[0] == b'{'
        && b[37] == b'}'
        && is_hex_block(&name[1..9])
        && b[9] == b'-'
        && is_hex_block(&name[10..14])
        && b[14] == b'-'
        && is_hex_block(&name[15..19])
        && b[19] == b'-'
        && is_hex_block(&name[20..24])
        && b[24] == b'-'
        && is_hex_block(&name[25..37])
}

fn is_hex_block(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_hexdigit())
}

// ---------------------------------------------------------------------------
// Internal scan model
// ---------------------------------------------------------------------------

struct FileInfo {
    name: String,
    relative_path: String,
    absolute_path: PathBuf,
    extension: String,
    /// SHA-256 hex digest of file contents. None if hashing failed (e.g. permission error).
    sha256: Option<String>,
    /// File modification time as seconds since Unix epoch. None if unavailable.
    /// Used by the duplicate ranker in #83.
    #[allow(dead_code)]
    modified_secs: Option<u64>,
}

struct FolderNode {
    name: String,
    /// Relative to the selected root. Empty string for the root itself.
    relative_path: String,
    absolute_path: PathBuf,
    /// 0 = selected root itself.
    depth: usize,
    /// Relative path of the direct parent. None for root.
    parent_relative_path: Option<String>,
    /// Files excluding system metadata files.
    real_file_count: usize,
    child_folder_count: usize,
    /// Direct (non-recursive) files, for misplaced-file detection.
    direct_files: Vec<FileInfo>,
}

fn is_metadata_file(name: &str) -> bool {
    METADATA_FILES.contains(&name)
}

// ---------------------------------------------------------------------------
// Hashing + duplicate detection
// ---------------------------------------------------------------------------

/// Compute SHA-256 hex digest for a file. Returns None on any I/O error.
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

/// Folder names that signal a low-quality destination — files here are almost
/// never the intended permanent home for a file.
///
/// Intentionally conservative: only names that are unambiguously temporary or
/// system-generated. Names like "misc", "inbox", "scratch" are excluded because
/// they can represent deliberate organizational choices.
///
/// TODO (#81): make this list user-configurable in the Settings screen so users
/// can add or remove entries to match their own folder conventions.
const JUNK_FOLDER_NAMES: &[&str] = &[
    "temp", "tmp", "downloads", "desktop", "untitled", "new folder",
];

/// Filename substrings (lowercase) that indicate a copy artifact —
/// the file is likely a duplicate rather than the canonical original.
const COPY_ARTIFACT_PATTERNS: &[&str] = &[
    " copy", "(copy)", " - copy", "_copy", "_backup", "_bak", "_old",
    " (2)", " (3)", " (4)", " (5)",
    "_2.", "_3.", "_4.", "_5.",
];

/// Penalty score for a single copy (lower = better candidate to keep).
///
/// Returns `(score, reasons)` where `reasons` explains the penalties found.
/// Reasons are phrased negatively (why this copy is worse) so the caller
/// can build a positive explanation for the winner.
pub fn penalty_score(rel_path: &str) -> (u32, Vec<String>) {
    let mut score = 0u32;
    let mut reasons: Vec<String> = Vec::new();

    // Split into path components; last component is the filename.
    let components: Vec<&str> = rel_path.split('/').collect();
    let folder_components = if components.len() > 1 {
        &components[..components.len() - 1]
    } else {
        &[][..]
    };
    let file_name = components.last().copied().unwrap_or("");
    let file_name_lower = file_name.to_lowercase();

    // Remove extension for artifact pattern matching (avoid false hits on ".bak").
    let stem_lower = if let Some(dot) = file_name_lower.rfind('.') {
        &file_name_lower[..dot]
    } else {
        &file_name_lower
    };

    // — Junk folder penalty (10 pts per junk folder in path) —
    for folder in folder_components {
        let lower = folder.to_lowercase();
        if JUNK_FOLDER_NAMES.contains(&lower.as_str()) {
            score += 10;
            reasons.push(format!("{}/ is a low-quality destination", folder));
        }
    }

    // — Folder naming quality (3 pts per folder with Unknown/messy convention) —
    // Uses classify_convention: Unknown means the name doesn't follow any
    // recognizable pattern (not title case, snake, camel, or kebab).
    for folder in folder_components {
        if matches!(
            classify_convention(folder),
            NamingConvention::Unknown
        ) {
            score += 3;
            reasons.push(format!("{}/ has a non-standard folder name", folder));
        }
    }

    // — Copy artifact penalty (5 pts if filename looks like a copy) —
    for pattern in COPY_ARTIFACT_PATTERNS {
        if stem_lower.contains(pattern) {
            score += 5;
            reasons.push(format!(
                "\"{}\" appears to be a copy (contains \"{}\")",
                file_name, pattern
            ));
            break; // one artifact penalty per file is enough
        }
    }

    // — Path depth penalty (1 pt per folder level beyond 1) —
    let depth = folder_components.len();
    if depth > 1 {
        score += (depth - 1) as u32;
        // Depth reasons are only surfaced at group level when it's the deciding factor.
    }

    (score, reasons)
}

/// Group files by SHA-256 hash (internal — returns full FileInfo per group).
fn group_files_by_hash<'a>(files: &[&'a FileInfo]) -> Vec<Vec<&'a FileInfo>> {
    let mut by_hash: HashMap<&str, Vec<&FileInfo>> = HashMap::new();
    for file in files {
        if let Some(hash) = &file.sha256 {
            by_hash.entry(hash).or_default().push(file);
        }
    }
    let mut groups: Vec<Vec<&FileInfo>> = by_hash
        .into_values()
        .filter(|g| g.len() >= 2)
        .collect();
    // Stable sort so output order is deterministic.
    groups.sort_by(|a, b| a[0].relative_path.cmp(&b[0].relative_path));
    groups
}

/// Rank a single duplicate group and return a `DuplicateGroup` with the
/// suggested keeper and the reasoning.
fn rank_group(group: &[&FileInfo]) -> DuplicateGroup {
    // Score every copy.
    let scored: Vec<(&FileInfo, u32, Vec<String>)> = group
        .iter()
        .map(|f| {
            let (s, r) = penalty_score(&f.relative_path);
            (*f, s, r)
        })
        .collect();

    let min_score = scored.iter().map(|(_, s, _)| *s).min().unwrap_or(0);
    let candidates: Vec<&(&FileInfo, u32, Vec<String>)> = scored
        .iter()
        .filter(|(_, s, _)| *s == min_score)
        .collect();

    // If multiple candidates have the same minimum penalty, use timestamp as
    // a tiebreaker (newer = keep).
    let best_mtime = candidates
        .iter()
        .filter_map(|(f, _, _)| f.modified_secs)
        .max();

    let final_candidates: Vec<&&(&FileInfo, u32, Vec<String>)> = match best_mtime {
        Some(mtime) => candidates
            .iter()
            .filter(|(f, _, _)| f.modified_secs == Some(mtime))
            .collect(),
        None => candidates.iter().collect(),
    };

    let ambiguous = final_candidates.len() > 1;

    // Pick the first final candidate (alphabetically stable after sorting).
    let (winner, _, winner_reasons) = final_candidates[0];

    // Build human-readable reasons explaining the choice.
    let mut reasons: Vec<String> = Vec::new();

    // Describe why losers lost (gives context for why winner was picked).
    let loser_reasons: Vec<String> = scored
        .iter()
        .filter(|(f, _, _)| f.relative_path != winner.relative_path)
        .flat_map(|(_, _, r)| r.clone())
        .collect();

    if !loser_reasons.is_empty() {
        reasons.extend(loser_reasons);
    } else if best_mtime.is_some() && !ambiguous {
        reasons.push("Newer file (timestamp tiebreaker)".to_string());
    } else if ambiguous {
        reasons.push("All copies have equal quality — manual selection required".to_string());
    } else {
        reasons.push("All copies scored equally".to_string());
    }

    // Drop winner_reasons (they describe the winner's own penalties, which are
    // the same as the losers' if it's a tie — not useful to surface).
    let _ = winner_reasons;

    let paths: Vec<String> = {
        let mut p: Vec<String> = group
            .iter()
            .map(|f| f.relative_path.clone())
            .collect();
        p.sort();
        p
    };

    DuplicateGroup {
        paths,
        suggested_keep: winner.relative_path.clone(),
        reasons,
        ambiguous,
    }
}

/// Detect duplicate files and rank each group to produce a suggested keeper.
/// Returns one `DuplicateGroup` per set of identical files (2+ members).
/// Groups are sorted by their first path for deterministic output.
fn resolve_duplicate_groups(files: &[&FileInfo]) -> Vec<DuplicateGroup> {
    let raw_groups = group_files_by_hash(files);
    raw_groups.iter().map(|g| rank_group(g)).collect()
}

// ---------------------------------------------------------------------------
// JSON output structures (Rust → Flutter)
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ProgressEvent<'a> {
    #[serde(rename = "type")]
    event_type: &'static str,
    folders_scanned: usize,
    current_path: &'a str,
}

#[derive(Serialize)]
pub struct Finding {
    pub id: String,
    pub finding_type: String,
    pub severity: String,
    pub path: String,
    pub absolute_path: String,
    pub display_name: String,
    pub action: String,
    pub destination: Option<String>,
    pub absolute_destination: Option<String>,
    pub inference_basis: String,
    pub triggered_by: Option<String>,
}

#[derive(Serialize)]
struct ScanError {
    path: String,
    message: String,
}

/// A resolved duplicate group: the set of identical files with a suggested keeper.
#[derive(Serialize)]
pub struct DuplicateGroup {
    /// All relative paths in this group (sorted).
    pub paths: Vec<String>,
    /// The path the engine recommends keeping.
    pub suggested_keep: String,
    /// Human-readable reasons explaining why `suggested_keep` was chosen.
    pub reasons: Vec<String>,
    /// True when the engine cannot determine a clear winner (equal scores + timestamps).
    /// The user must choose manually.
    pub ambiguous: bool,
}

/// A single item in the full directory listing emitted with the findings payload.
#[derive(Serialize)]
struct DirectoryEntry {
    /// Path relative to the selected folder (e.g. "cborn/My Documents/CBORN DOCS").
    relative_path: String,
    /// "folder" or "file"
    entry_type: &'static str,
    /// File size in bytes. None for folders.
    #[serde(skip_serializing_if = "Option::is_none")]
    size_bytes: Option<u64>,
}

#[derive(Serialize)]
struct FindingsPayload {
    #[serde(rename = "type")]
    event_type: &'static str,
    selected_folder: String,
    scanned_at: String,
    total_folders: usize,
    findings: Vec<Finding>,
    errors: Vec<ScanError>,
    /// Full directory listing — all folders and files under the selected root.
    entries: Vec<DirectoryEntry>,
    /// Resolved duplicate groups. Each group has a suggested keeper and reasons.
    /// Empty when no duplicates are found.
    duplicate_groups: Vec<DuplicateGroup>,
}

// ---------------------------------------------------------------------------
// JSON input structures (Flutter → Rust)
// ---------------------------------------------------------------------------

/// Discriminated union for commands sent over stdin. We peek at "type" first.
#[derive(Deserialize)]
struct CommandEnvelope {
    #[serde(rename = "type")]
    command_type: String,
}

/// Legacy in-place execution plan (kept for compatibility during transition).
#[derive(Deserialize)]
struct ExecutionPlan {
    #[allow(dead_code)]
    #[serde(rename = "type")]
    event_type: String,
    selected_folder: String,
    session_id: String,
    actions: Vec<ExecutionAction>,
}

#[derive(Deserialize)]
struct ExecutionAction {
    finding_id: String,
    action: String,
    absolute_path: String,
    absolute_destination: Option<String>,
}

/// Copy-then-swap: build phase command.
#[derive(Deserialize)]
struct BuildCommand {
    #[allow(dead_code)]
    #[serde(rename = "type")]
    command_type: String,
    /// Absolute path of the source directory (never modified).
    source_path: String,
    /// Absolute path where the rationalized copy will be created.
    target_path: String,
    session_id: String,
    actions: Vec<ExecutionAction>,
    /// Relative paths of duplicate copies to omit from the target.
    /// These are the non-kept copies from resolved duplicate groups.
    #[serde(default)]
    duplicate_removals: Vec<String>,
}

/// Copy-then-swap: swap phase command.
#[derive(Deserialize)]
struct SwapCommand {
    #[allow(dead_code)]
    #[serde(rename = "type")]
    command_type: String,
    /// The original source directory (will be renamed to source.OLD).
    source_path: String,
    /// The rationalized copy (will be renamed to source name).
    target_path: String,
}

// ---------------------------------------------------------------------------
// Execution result structures (Rust → Flutter)
// ---------------------------------------------------------------------------

#[derive(Serialize, Clone)]
struct ExecutionEntry {
    finding_id: String,
    action: String,
    absolute_path: String,
    absolute_destination: String,
    outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Serialize)]
struct ExecutionResult {
    #[serde(rename = "type")]
    event_type: &'static str,
    session_id: String,
    total: usize,
    succeeded: usize,
    skipped: usize,
    failed: usize,
    log_path: String,
    quarantine_path: String,
    entries: Vec<ExecutionEntry>,
}

/// Emitted periodically during the build phase.
#[derive(Serialize)]
struct BuildProgressEvent {
    #[serde(rename = "type")]
    event_type: &'static str,
    folders_done: usize,
    folders_total: usize,
    current: String,
}

/// Emitted when the build phase completes.
#[derive(Serialize)]
struct BuildCompleteEvent {
    #[serde(rename = "type")]
    event_type: &'static str,
    session_id: String,
    target_path: String,
    folders_copied: usize,
    files_copied: usize,
    folders_omitted: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

/// Emitted when the swap phase completes.
#[derive(Serialize)]
struct SwapCompleteEvent {
    #[serde(rename = "type")]
    event_type: &'static str,
    old_path: String,
    new_path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

// ---------------------------------------------------------------------------
// R6 — Progress streaming
// ---------------------------------------------------------------------------

fn emit_json<T: Serialize>(value: &T) {
    if let Ok(json) = serde_json::to_string(value) {
        println!("{}", json);
        io::stdout().flush().ok();
    }
}

fn emit_scan_progress(folders_scanned: usize, current_path: &str) {
    emit_json(&ProgressEvent {
        event_type: "progress",
        folders_scanned,
        current_path,
    });
}

// ---------------------------------------------------------------------------
// R2 — Structural metadata collector
// ---------------------------------------------------------------------------

fn scan_directory(
    root: &Path,
    current: &Path,
    depth: usize,
    folders: &mut Vec<FolderNode>,
    errors: &mut Vec<ScanError>,
) {
    let read_dir = match fs::read_dir(current) {
        Ok(rd) => rd,
        Err(e) => {
            errors.push(ScanError {
                path: current.to_string_lossy().into_owned(),
                message: e.to_string(),
            });
            return;
        }
    };

    let relative_path = current
        .strip_prefix(root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();

    let name = if depth == 0 {
        current
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    } else {
        current
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    };

    let parent_relative_path = if depth == 0 {
        None
    } else {
        current
            .parent()
            .and_then(|p| p.strip_prefix(root).ok())
            .map(|p| p.to_string_lossy().into_owned())
    };

    let mut real_file_count = 0usize;
    let mut child_folder_count = 0usize;
    let mut direct_files: Vec<FileInfo> = Vec::new();
    let mut child_dirs: Vec<PathBuf> = Vec::new();

    for entry_result in read_dir {
        let entry = match entry_result {
            Ok(e) => e,
            Err(e) => {
                errors.push(ScanError {
                    path: current.to_string_lossy().into_owned(),
                    message: e.to_string(),
                });
                continue;
            }
        };
        let path = entry.path();
        let entry_name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();

        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(e) => {
                errors.push(ScanError {
                    path: path.to_string_lossy().into_owned(),
                    message: e.to_string(),
                });
                continue;
            }
        };

        if metadata.is_dir() {
            // Skip GUID folders entirely — COM/OLE artifacts, never user data (#57).
            if is_guid_folder(&entry_name) {
                continue;
            }
            child_folder_count += 1;
            child_dirs.push(path);
        } else if metadata.is_file() {
            if !is_metadata_file(&entry_name) {
                real_file_count += 1;
            }
            let ext = path
                .extension()
                .map(|e| e.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            let file_relative = path
                .strip_prefix(root)
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let modified_secs = metadata
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs());
            // Skip hashing system metadata files (they're never counted or shown).
            let sha256 = if is_metadata_file(&entry_name) {
                None
            } else {
                hash_file(&path)
            };
            direct_files.push(FileInfo {
                name: entry_name,
                relative_path: file_relative,
                absolute_path: path,
                extension: ext,
                sha256,
                modified_secs,
            });
        }
    }

    // Emit progress for this folder before recursing.
    emit_scan_progress(folders.len() + 1, &relative_path);

    folders.push(FolderNode {
        name,
        relative_path,
        absolute_path: current.to_path_buf(),
        depth,
        parent_relative_path,
        real_file_count,
        child_folder_count,
        direct_files,
    });

    for child_dir in child_dirs {
        scan_directory(root, &child_dir, depth + 1, folders, errors);
    }
}

// ---------------------------------------------------------------------------
// R4 — Finding generator
// ---------------------------------------------------------------------------

fn convention_display(c: NamingConvention) -> &'static str {
    match c {
        NamingConvention::TitleCase => "Title Case",
        NamingConvention::SnakeCase => "snake_case",
        NamingConvention::CamelCase => "camelCase",
        NamingConvention::KebabCase => "kebab-case",
        NamingConvention::LowerCase => "lowercase",
        NamingConvention::Unknown => "unknown",
    }
}

/// Propose a destination for a folder that exceeds the nesting threshold.
/// Moves the folder to be a direct child of the ancestor at depth `threshold`,
/// making it land at depth `threshold + 1`... actually we want it AT `threshold`.
/// So we place it under the ancestor at depth `threshold - 1`.
fn compute_flatten_destination(
    root: &Path,
    folder_path: &Path,
    threshold: usize,
) -> Option<(String, String)> {
    let relative = folder_path.strip_prefix(root).ok()?;
    let components: Vec<_> = relative.components().collect();
    // depth = number of path components relative to root
    let depth = components.len();
    if depth <= threshold {
        return None;
    }
    // Ancestor at depth (threshold - 1) has that many components
    let ancestor_component_count = threshold.saturating_sub(1);
    let ancestor_rel: PathBuf = components[..ancestor_component_count].iter().collect();
    let folder_name = folder_path.file_name()?;
    let dest_rel = ancestor_rel.join(folder_name);
    let dest_abs = root.join(&dest_rel);
    Some((
        dest_rel.to_string_lossy().into_owned(),
        dest_abs.to_string_lossy().into_owned(),
    ))
}

/// Generate misplaced-file findings.
/// An extension is considered to "belong" to a top-level subtree when ≥ 90%
/// of files with that extension appear under it. Files outside that canonical
/// subtree are flagged. Requires at least 4 data points before inferring.
fn generate_misplaced_file_findings(
    root: &Path,
    folders: &[FolderNode],
    id_counter: &mut usize,
) -> Vec<Finding> {
    // ext → Vec<(rel_path, abs_path, top_level_ancestor_name)>
    let mut ext_locs: HashMap<&str, Vec<(&str, &Path, &str)>> = HashMap::new();

    for folder in folders {
        let top_ancestor = if folder.depth == 0 {
            // Files directly in the root — no top-level ancestor
            ""
        } else {
            // First path component of relative_path is the depth-1 folder name
            folder
                .relative_path
                .split('/')
                .next()
                .unwrap_or("")
        };

        for file in &folder.direct_files {
            if file.extension.is_empty() {
                continue;
            }
            ext_locs
                .entry(&file.extension)
                .or_default()
                .push((&file.relative_path, &file.absolute_path, top_ancestor));
        }
    }

    let mut findings = Vec::new();

    for (ext, locations) in &ext_locs {
        if locations.len() < 4 {
            continue;
        }

        // Count per top-level ancestor
        let mut ancestor_counts: HashMap<&str, usize> = HashMap::new();
        for (_, _, ancestor) in locations {
            *ancestor_counts.entry(ancestor).or_default() += 1;
        }

        let total = locations.len();
        let dominant = ancestor_counts
            .iter()
            .find(|&(_, &count)| count * 100 / total >= 90)
            .map(|(&name, &count)| (name, count));

        let Some((canonical, canonical_count)) = dominant else {
            continue;
        };

        if canonical.is_empty() {
            // Files are in root — no meaningful subtree to propose
            continue;
        }

        for (rel_path, abs_path, ancestor) in locations {
            if *ancestor != canonical {
                *id_counter += 1;
                let id = format!("f{}", id_counter);
                let file_name = abs_path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let dest_rel = format!("{}/{}", canonical, file_name);
                let dest_abs = root.join(&dest_rel);

                findings.push(Finding {
                    id,
                    finding_type: "misplaced_file".to_string(),
                    severity: "warning".to_string(),
                    path: rel_path.to_string(),
                    absolute_path: abs_path.to_string_lossy().into_owned(),
                    display_name: file_name,
                    action: "move".to_string(),
                    destination: Some(dest_rel),
                    absolute_destination: Some(dest_abs.to_string_lossy().into_owned()),
                    inference_basis: format!(
                        ".{} files appear in {}/{} cases under {}/",
                        ext, canonical_count, total, canonical
                    ),
                    triggered_by: None,
                });
            }
        }
    }

    findings
}

// ---------------------------------------------------------------------------
// R5 — Dependency chaining (one-level cascade)
// ---------------------------------------------------------------------------

/// For each empty_folder finding, check if removing it would make its direct
/// parent empty. If so, surface the parent as a dependent finding.
/// Only one level of cascade — re-scan handles the rest.
fn generate_cascade_findings(
    folders: &[FolderNode],
    empty_folder_ids: &HashMap<String, String>,
    id_counter: &mut usize,
) -> Vec<Finding> {
    let folder_map: HashMap<&str, &FolderNode> = folders
        .iter()
        .map(|f| (f.relative_path.as_str(), f))
        .collect();

    // For each parent: how many of its direct subfolders are flagged as empty?
    let mut parent_flagged_count: HashMap<String, usize> = HashMap::new();
    for rel_path in empty_folder_ids.keys() {
        if let Some(f) = folder_map.get(rel_path.as_str()) {
            if let Some(parent_key) = &f.parent_relative_path {
                *parent_flagged_count.entry(parent_key.clone()).or_default() += 1;
            }
        }
    }

    let mut cascade = Vec::new();

    for (parent_rel, flagged_count) in &parent_flagged_count {
        let Some(parent) = folder_map.get(parent_rel.as_str()) else {
            continue;
        };
        if parent.depth == 0 {
            continue; // Never cascade to the selected root
        }
        // Parent would become empty if all child folders are being removed and
        // it has no real files of its own — and it isn't already flagged independently.
        let would_become_empty = parent.real_file_count == 0
            && *flagged_count >= parent.child_folder_count
            && parent.child_folder_count > 0;

        if would_become_empty && !empty_folder_ids.contains_key(parent_rel.as_str()) {
            // Pick the first triggering child as the `triggered_by` reference.
            let triggering_id = empty_folder_ids
                .iter()
                .find(|(rel, _)| {
                    folder_map
                        .get(rel.as_str())
                        .and_then(|f| f.parent_relative_path.as_deref())
                        == Some(parent_rel)
                })
                .map(|(_, id)| id.clone());

            let Some(triggered_by) = triggering_id else {
                continue;
            };

            // Find the name of any triggering child for the inference_basis message.
            let child_name = empty_folder_ids
                .keys()
                .find(|rel| {
                    folder_map
                        .get(rel.as_str())
                        .and_then(|f| f.parent_relative_path.as_deref())
                        == Some(parent_rel)
                })
                .and_then(|rel| folder_map.get(rel.as_str()))
                .map(|f| f.name.as_str())
                .unwrap_or("child folder");

            *id_counter += 1;
            let id = format!("f{}", id_counter);

            cascade.push(Finding {
                id,
                finding_type: "empty_folder".to_string(),
                severity: "issue".to_string(),
                path: parent.relative_path.clone(),
                absolute_path: parent.absolute_path.to_string_lossy().into_owned(),
                display_name: parent.name.clone(),
                action: "remove".to_string(),
                destination: None,
                absolute_destination: None,
                inference_basis: format!(
                    "Will become empty if {} is removed",
                    child_name
                ),
                triggered_by: Some(triggered_by),
            });
        }
    }

    cascade
}

fn generate_findings(root: &Path, folders: &[FolderNode]) -> Vec<Finding> {
    let mut findings: Vec<Finding> = Vec::new();
    let mut id_counter = 0usize;

    // Build sibling groups: parent_relative_path → Vec<&folder_name>
    let mut sibling_groups: HashMap<String, Vec<&str>> = HashMap::new();
    for folder in folders {
        if folder.depth == 0 {
            continue;
        }
        let parent_key = folder
            .parent_relative_path
            .as_deref()
            .unwrap_or("")
            .to_string();
        sibling_groups
            .entry(parent_key)
            .or_default()
            .push(&folder.name);
    }

    // Compute dominant convention per sibling group (90% threshold, 3 min samples).
    let dominant_by_parent: HashMap<String, NamingConvention> = sibling_groups
        .iter()
        .filter_map(|(parent, names)| {
            let dom = dominant_convention(names, 0.9, 3)?;
            Some((parent.clone(), dom))
        })
        .collect();

    // Tracks empty_folder findings: relative_path → finding_id
    // Used for cascade detection (R5).
    let mut empty_folder_ids: HashMap<String, String> = HashMap::new();

    for folder in folders {
        if folder.depth == 0 {
            continue; // Never flag the root itself
        }

        // ── empty_folder ──────────────────────────────────────────────────
        let is_empty = folder.real_file_count == 0 && folder.child_folder_count == 0;
        if is_empty {
            id_counter += 1;
            let id = format!("f{}", id_counter);
            empty_folder_ids.insert(folder.relative_path.clone(), id.clone());
            findings.push(Finding {
                id,
                finding_type: "empty_folder".to_string(),
                severity: "issue".to_string(),
                path: folder.relative_path.clone(),
                absolute_path: folder.absolute_path.to_string_lossy().into_owned(),
                display_name: folder.name.clone(),
                action: "remove".to_string(),
                destination: None,
                absolute_destination: None,
                inference_basis: "Folder contains no files".to_string(),
                triggered_by: None,
            });
        }

        // ── excessive_nesting ─────────────────────────────────────────────
        if folder.depth > NESTING_DEPTH_THRESHOLD {
            let dest = compute_flatten_destination(root, &folder.absolute_path, NESTING_DEPTH_THRESHOLD);
            id_counter += 1;
            let id = format!("f{}", id_counter);
            findings.push(Finding {
                id,
                finding_type: "excessive_nesting".to_string(),
                severity: "warning".to_string(),
                path: folder.relative_path.clone(),
                absolute_path: folder.absolute_path.to_string_lossy().into_owned(),
                display_name: folder.name.clone(),
                action: "move".to_string(),
                destination: dest.as_ref().map(|(rel, _)| rel.clone()),
                absolute_destination: dest.as_ref().map(|(_, abs)| abs.clone()),
                inference_basis: format!(
                    "Folder depth is {}; threshold is {}",
                    folder.depth, NESTING_DEPTH_THRESHOLD
                ),
                triggered_by: None,
            });
        }

        // ── naming_inconsistency ──────────────────────────────────────────
        // Only when the folder has no other findings (already flagged empty folders
        // don't need a rename proposal too). Reserved names are never renamed.
        if !is_empty && !RESERVED_FOLDER_NAMES.contains(&folder.name.as_str()) {
            if let Some(parent_key) = &folder.parent_relative_path {
                if let Some(&dominant) = dominant_by_parent.get(parent_key) {
                    if let Some(renamed) = suggest_rename(&folder.name, dominant) {
                        let dest_rel = if parent_key.is_empty() {
                            renamed.clone()
                        } else {
                            format!("{}/{}", parent_key, renamed)
                        };
                        let dest_abs = root.join(&dest_rel);

                        // Compute actual percentage for the inference_basis string.
                        let pct = sibling_groups
                            .get(parent_key)
                            .map(|siblings| {
                                let matching = siblings
                                    .iter()
                                    .filter(|&&n| classify_convention(n) == dominant)
                                    .count();
                                if siblings.is_empty() {
                                    0
                                } else {
                                    matching * 100 / siblings.len()
                                }
                            })
                            .unwrap_or(90);

                        id_counter += 1;
                        let id = format!("f{}", id_counter);
                        findings.push(Finding {
                            id,
                            finding_type: "naming_inconsistency".to_string(),
                            severity: "issue".to_string(),
                            path: folder.relative_path.clone(),
                            absolute_path: folder.absolute_path.to_string_lossy().into_owned(),
                            display_name: folder.name.clone(),
                            action: "rename".to_string(),
                            destination: Some(dest_rel),
                            absolute_destination: Some(dest_abs.to_string_lossy().into_owned()),
                            inference_basis: format!(
                                "{} used by {}% of sibling folders",
                                convention_display(dominant),
                                pct
                            ),
                            triggered_by: None,
                        });
                    }
                }
            }
        }
    }

    // ── misplaced_file ────────────────────────────────────────────────────
    let misplaced = generate_misplaced_file_findings(root, folders, &mut id_counter);
    findings.extend(misplaced);

    // ── cascade (R5) ──────────────────────────────────────────────────────
    let cascade = generate_cascade_findings(folders, &empty_folder_ids, &mut id_counter);
    findings.extend(cascade);

    findings
}

// ---------------------------------------------------------------------------
// R7 — Findings JSON output
// ---------------------------------------------------------------------------

fn current_timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    unix_secs_to_iso8601(secs)
}

fn unix_secs_to_iso8601(secs: u64) -> String {
    let sec = (secs % 60) as u32;
    let min = ((secs / 60) % 60) as u32;
    let hour = ((secs / 3600) % 24) as u32;
    let days = (secs / 86400) as i64;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hour, min, sec
    )
}

/// Convert days since Unix epoch (1970-01-01) to (year, month, day).
/// Uses Howard Hinnant's algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era: i64 = if z >= 0 { z / 146_097 } else { (z - 146_096) / 146_097 };
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// ---------------------------------------------------------------------------
// R8 — Execution engine
// ---------------------------------------------------------------------------

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

fn quarantine_base() -> PathBuf {
    home_dir().join(".filesteward").join("quarantine")
}

fn logs_base() -> PathBuf {
    home_dir().join(".filesteward").join("logs")
}

fn execute_plan(
    plan: &ExecutionPlan,
    findings: &[Finding],
) -> ExecutionResult {
    let session_id = &plan.session_id;
    let quarantine_session = quarantine_base().join(session_id);
    let log_path = logs_base().join(format!("{}.json", session_id));
    let selected_root = Path::new(&plan.selected_folder);

    // Pre-create quarantine and log directories (non-fatal on failure).
    let _ = fs::create_dir_all(&quarantine_session);
    let _ = fs::create_dir_all(logs_base());

    // Build a quick lookup: finding_id → Finding (for display_name etc.)
    let findings_by_id: HashMap<&str, &Finding> = findings
        .iter()
        .map(|f| (f.id.as_str(), f))
        .collect();

    let mut entries: Vec<ExecutionEntry> = Vec::new();
    let mut succeeded = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;

    for action in &plan.actions {
        let src = Path::new(&action.absolute_path);

        let (outcome, error, actual_dest) = match action.action.as_str() {
            "remove" => execute_remove(src, selected_root, &quarantine_session),
            "rename" | "move" => {
                let dest_str = action.absolute_destination.as_deref().unwrap_or("");
                if dest_str.is_empty() {
                    (
                        "failed".to_string(),
                        Some("No destination specified".to_string()),
                        dest_str.to_string(),
                    )
                } else {
                    execute_move(src, Path::new(dest_str))
                }
            }
            other => (
                "skipped".to_string(),
                Some(format!("Unknown action: {}", other)),
                String::new(),
            ),
        };

        match outcome.as_str() {
            "succeeded" => succeeded += 1,
            "skipped" => skipped += 1,
            _ => failed += 1,
        }

        entries.push(ExecutionEntry {
            finding_id: action.finding_id.clone(),
            action: action.action.clone(),
            absolute_path: action.absolute_path.clone(),
            absolute_destination: actual_dest,
            outcome,
            error,
        });

        // Suppress unused variable warning when finding is not in the map.
        let _ = findings_by_id.get(action.finding_id.as_str());
    }

    let result = ExecutionResult {
        event_type: "execution_result",
        session_id: session_id.clone(),
        total: plan.actions.len(),
        succeeded,
        skipped,
        failed,
        log_path: log_path.to_string_lossy().into_owned(),
        quarantine_path: quarantine_session.to_string_lossy().into_owned(),
        entries,
    };

    // R9 — Write execution log
    write_execution_log(&log_path, &result);

    result
}

/// Move `src` into `quarantine_session`, preserving its path relative to `selected_root`.
fn execute_remove(
    src: &Path,
    selected_root: &Path,
    quarantine_session: &Path,
) -> (String, Option<String>, String) {
    let relative = match src.strip_prefix(selected_root) {
        Ok(r) => r,
        Err(_) => {
            return (
                "failed".to_string(),
                Some("Path is not inside selected folder".to_string()),
                String::new(),
            )
        }
    };

    if !src.exists() {
        return (
            "skipped".to_string(),
            Some("Source does not exist".to_string()),
            String::new(),
        );
    }

    let dest = quarantine_session.join(relative);

    if let Some(parent) = dest.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            return (
                "failed".to_string(),
                Some(format!("Could not create quarantine directory: {}", e)),
                dest.to_string_lossy().into_owned(),
            );
        }
    }

    if dest.exists() {
        // Already quarantined in a prior session — source is gone. Report skipped.
        return (
            "skipped".to_string(),
            Some("Already quarantined in a prior session".to_string()),
            dest.to_string_lossy().into_owned(),
        );
    }

    move_with_cross_device_fallback(src, &dest)
}

/// Rename src → dest, falling back to copy-then-delete when source and
/// destination are on different filesystems (EXDEV / os error 18). (#59)
fn move_with_cross_device_fallback(
    src: &Path,
    dest: &Path,
) -> (String, Option<String>, String) {
    let dest_str = dest.to_string_lossy().into_owned();
    match fs::rename(src, dest) {
        Ok(()) => ("succeeded".to_string(), None, dest_str),
        Err(e) if e.raw_os_error() == Some(18) => {
            // Cross-device: copy then delete.
            match copy_dir_all(src, dest) {
                Ok(()) => match fs::remove_dir_all(src) {
                    Ok(()) => ("succeeded".to_string(), None, dest_str),
                    Err(re) => (
                        "failed".to_string(),
                        Some(format!("Copied but could not remove source: {}", re)),
                        dest_str,
                    ),
                },
                Err(ce) => (
                    "failed".to_string(),
                    Some(format!("Cross-device copy failed: {}", ce)),
                    dest_str,
                ),
            }
        }
        Err(e) => ("failed".to_string(), Some(e.to_string()), dest_str),
    }
}

/// Recursively copy a directory tree from src to dest.
fn copy_dir_all(src: &Path, dest: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dest)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        if ty.is_dir() {
            copy_dir_all(&entry.path(), &dest.join(entry.file_name()))?;
        } else {
            fs::copy(entry.path(), dest.join(entry.file_name()))?;
        }
    }
    Ok(())
}

/// Rename or move `src` to `dest`. Creates destination parent directories.
/// For renames (same parent), auto-suffixes if dest already exists (#59).
/// For moves (different parent), reports conflict if dest already exists.
fn execute_move(src: &Path, dest: &Path) -> (String, Option<String>, String) {
    if !src.exists() {
        return (
            "skipped".to_string(),
            Some("Source does not exist".to_string()),
            dest.to_string_lossy().into_owned(),
        );
    }

    // Resolve the actual destination, handling collisions.
    let actual_dest = if dest.exists() {
        let is_rename = src.parent() == dest.parent();
        if is_rename {
            // Auto-suffix: try _2, _3, … until free.
            match find_available_suffixed(dest) {
                Some(d) => d,
                None => {
                    return (
                        "failed".to_string(),
                        Some("Could not find available suffixed destination".to_string()),
                        dest.to_string_lossy().into_owned(),
                    )
                }
            }
        } else {
            // Move collision — report conflict, leave source untouched.
            return (
                "failed".to_string(),
                Some("Destination already exists — move conflict requires manual resolution".to_string()),
                dest.to_string_lossy().into_owned(),
            );
        }
    } else {
        dest.to_path_buf()
    };

    if let Some(parent) = actual_dest.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            return (
                "failed".to_string(),
                Some(format!("Could not create destination directory: {}", e)),
                actual_dest.to_string_lossy().into_owned(),
            );
        }
    }

    move_with_cross_device_fallback(src, &actual_dest)
}

/// Find the first available path by appending _2, _3, … to the stem.
fn find_available_suffixed(dest: &Path) -> Option<PathBuf> {
    let parent = dest.parent()?;
    let stem = dest.file_name()?.to_string_lossy().into_owned();
    for n in 2u32..=99 {
        let candidate = parent.join(format!("{}_{}", stem, n));
        if !candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// R9 — Execution log
// ---------------------------------------------------------------------------

fn write_execution_log(log_path: &Path, result: &ExecutionResult) {
    if let Ok(json) = serde_json::to_string_pretty(result) {
        let _ = fs::write(log_path, json);
    }
}

// ---------------------------------------------------------------------------
// R1 — Public entry point (called from main.rs)
// ---------------------------------------------------------------------------

/// Run the rationalize pipeline for `folder_path`.
/// Scans, emits progress + findings, reads execution plan from stdin, executes.
pub fn run(folder_path: &str) {
    let root = Path::new(folder_path);

    if !root.exists() || !root.is_dir() {
        let payload = FindingsPayload {
            event_type: "findings",
            selected_folder: folder_path.to_string(),
            scanned_at: current_timestamp(),
            total_folders: 0,
            findings: vec![],
            errors: vec![ScanError {
                path: folder_path.to_string(),
                message: "Path does not exist or is not a directory".to_string(),
            }],
            entries: vec![],
            duplicate_groups: vec![],
        };
        emit_json(&payload);
        return;
    }

    let mut folders: Vec<FolderNode> = Vec::new();
    let mut errors: Vec<ScanError> = Vec::new();

    // R2 — collect structural metadata (also handles R6 progress events)
    scan_directory(root, root, 0, &mut folders, &mut errors);

    let total_folders = folders.len();
    let scanned_at = current_timestamp();

    // R4 + R5 — generate findings
    let findings = generate_findings(root, &folders);

    // R7 — build full directory entry list from scanned folders + their files.
    let mut entries: Vec<DirectoryEntry> = Vec::new();
    // Collect all files across all folders for duplicate detection.
    let mut all_files: Vec<&FileInfo> = Vec::new();
    for folder in &folders {
        if folder.relative_path.is_empty() {
            continue; // skip root itself — Flutter shows it as the header
        }
        entries.push(DirectoryEntry {
            relative_path: folder.relative_path.clone(),
            entry_type: "folder",
            size_bytes: None,
        });
        for file in &folder.direct_files {
            let size = fs::metadata(&file.absolute_path)
                .map(|m| m.len())
                .ok();
            entries.push(DirectoryEntry {
                relative_path: file.relative_path.clone(),
                entry_type: "file",
                size_bytes: size,
            });
            if !is_metadata_file(&file.name) {
                all_files.push(file);
            }
        }
    }
    entries.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));

    // Duplicate detection + ranking — group by hash, then score each group.
    let duplicate_groups = resolve_duplicate_groups(&all_files);

    // R7 — emit findings payload
    let payload = FindingsPayload {
        event_type: "findings",
        selected_folder: folder_path.to_string(),
        scanned_at,
        total_folders,
        findings,
        errors,
        entries,
        duplicate_groups,
    };
    emit_json(&payload);

    // Read command from stdin. Dispatch on "type" field.
    let stdin = io::stdin();
    let mut line = String::new();
    match stdin.lock().read_line(&mut line) {
        Ok(0) => return, // EOF — scan-only mode
        Ok(_) => {}
        Err(_) => return,
    }

    let line = line.trim();
    if line.is_empty() {
        return;
    }

    // Peek at the type field to dispatch.
    let command_type = serde_json::from_str::<CommandEnvelope>(line)
        .map(|e| e.command_type)
        .unwrap_or_default();

    match command_type.as_str() {
        "build" => {
            let cmd: BuildCommand = match serde_json::from_str(line) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("Failed to parse build command: {}", e);
                    return;
                }
            };
            let build_result = build_target(&cmd);
            let build_failed = build_result.error.is_some();
            emit_json(&build_result);

            if build_failed {
                return;
            }

            // Wait for the swap command.
            let mut swap_line = String::new();
            match io::stdin().lock().read_line(&mut swap_line) {
                Ok(0) | Err(_) => return, // user cancelled swap
                Ok(_) => {}
            }
            let swap_line = swap_line.trim();
            if swap_line.is_empty() {
                return;
            }
            let swap_cmd: SwapCommand = match serde_json::from_str(swap_line) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("Failed to parse swap command: {}", e);
                    return;
                }
            };
            let swap_result = execute_swap(&swap_cmd);
            emit_json(&swap_result);
        }
        _ => {
            // Legacy "execute" path — kept for compatibility during transition.
            let plan: ExecutionPlan = match serde_json::from_str(line) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("Failed to parse execution plan: {}", e);
                    return;
                }
            };
            let result = execute_plan(&plan, &payload.findings);
            emit_json(&result);
        }
    }
}

// ---------------------------------------------------------------------------
// Build phase — copy-then-swap engine
// ---------------------------------------------------------------------------

/// Mutable state threaded through the recursive build walk.
struct BuildState {
    folders_done: usize,
    folders_total: usize,
    files_copied: usize,
    folders_omitted: usize,
}

/// Recursively copy `src_dir` into `tgt_dir`, applying remap and skip tables.
///
/// `remap`: source absolute path → target absolute path (renamed/moved entries).
/// `skip`:  source absolute paths to omit entirely (removed entries).
///
/// Children of a remapped directory automatically land under the new target
/// location because `tgt_dir` is passed down — no global path translation needed.
fn build_dir(
    src_dir: &Path,
    tgt_dir: &Path,
    remap: &HashMap<PathBuf, PathBuf>,
    skip: &std::collections::HashSet<PathBuf>,
    state: &mut BuildState,
) -> io::Result<()> {
    fs::create_dir_all(tgt_dir)?;
    state.folders_done += 1;

    // Emit progress every 10 folders to avoid flooding stdout.
    if state.folders_done % 10 == 0 || state.folders_done == 1 {
        emit_json(&BuildProgressEvent {
            event_type: "build_progress",
            folders_done: state.folders_done,
            folders_total: state.folders_total,
            current: tgt_dir.to_string_lossy().into_owned(),
        });
    }

    for entry in fs::read_dir(src_dir)? {
        let entry = entry?;
        let src_path = entry.path();

        // Skip entries explicitly marked for removal.
        if skip.contains(&src_path) {
            state.folders_omitted += 1;
            continue;
        }

        // Compute target path: use remap if present, otherwise mirror under tgt_dir.
        let tgt_path = remap
            .get(&src_path)
            .cloned()
            .unwrap_or_else(|| tgt_dir.join(entry.file_name()));

        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            build_dir(&src_path, &tgt_path, remap, skip, state)?;
        } else if file_type.is_file() {
            if let Some(parent) = tgt_path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(&src_path, &tgt_path)?;
            state.files_copied += 1;
        }
        // Symlinks are intentionally skipped — they may point outside the tree.
    }

    Ok(())
}

/// Execute the build phase: copy source to target applying the approved plan.
///
/// Renames and moves are resolved as path remaps in the target tree.
/// Removes are omitted from the copy entirely.
/// Source directory is never touched.
fn build_target(cmd: &BuildCommand) -> BuildCompleteEvent {
    let source = Path::new(&cmd.source_path);
    let target = Path::new(&cmd.target_path);

    // Refuse to overwrite an existing target.
    if target.exists() {
        return BuildCompleteEvent {
            event_type: "build_complete",
            session_id: cmd.session_id.clone(),
            target_path: cmd.target_path.clone(),
            folders_copied: 0,
            files_copied: 0,
            folders_omitted: 0,
            error: Some(format!(
                "Target already exists: {}. Delete it or choose a different location.",
                cmd.target_path
            )),
        };
    }

    // Build remap and skip tables from the approved action list.
    let mut remap: HashMap<PathBuf, PathBuf> = HashMap::new();
    let mut skip: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();

    // Duplicate removals: relative paths → absolute source paths added to skip.
    for rel in &cmd.duplicate_removals {
        skip.insert(source.join(rel));
    }

    for action in &cmd.actions {
        let src = PathBuf::from(&action.absolute_path);
        match action.action.as_str() {
            "remove" => {
                skip.insert(src);
            }
            "rename" | "move" => {
                if let Some(dest_src_abs) = &action.absolute_destination {
                    // dest_src_abs is the destination expressed as an absolute path
                    // within the source tree (e.g. /source/photos/New Name).
                    // Translate to target tree by stripping the source prefix and
                    // prepending the target root.
                    let dest_src = Path::new(dest_src_abs);
                    let dest_rel = dest_src
                        .strip_prefix(source)
                        .unwrap_or(dest_src);
                    let dest_tgt = target.join(dest_rel);
                    remap.insert(src, dest_tgt);
                }
            }
            _ => {}
        }
    }

    // Count total source folders for progress reporting (best-effort).
    let folders_total = count_dirs(source);

    let mut state = BuildState {
        folders_done: 0,
        folders_total,
        files_copied: 0,
        folders_omitted: 0,
    };

    match build_dir(source, target, &remap, &skip, &mut state) {
        Ok(()) => BuildCompleteEvent {
            event_type: "build_complete",
            session_id: cmd.session_id.clone(),
            target_path: cmd.target_path.clone(),
            folders_copied: state.folders_done,
            files_copied: state.files_copied,
            folders_omitted: state.folders_omitted,
            error: None,
        },
        Err(e) => BuildCompleteEvent {
            event_type: "build_complete",
            session_id: cmd.session_id.clone(),
            target_path: cmd.target_path.clone(),
            folders_copied: state.folders_done,
            files_copied: state.files_copied,
            folders_omitted: state.folders_omitted,
            error: Some(e.to_string()),
        },
    }
}

/// Count directories under `path` (non-recursive count is good enough for progress).
fn count_dirs(path: &Path) -> usize {
    let Ok(entries) = fs::read_dir(path) else { return 1 };
    let mut count = 1usize;
    for entry in entries.flatten() {
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            count += count_dirs(&entry.path());
        }
    }
    count
}

/// Execute the swap phase:
/// 1. Rename source → source.OLD
/// 2. Rename target → source (original name)
fn execute_swap(cmd: &SwapCommand) -> SwapCompleteEvent {
    let source = Path::new(&cmd.source_path);
    let target = Path::new(&cmd.target_path);

    // Derive the .OLD path: same parent, same name with .OLD suffix.
    let old_path = {
        let name = source
            .file_name()
            .map(|n| format!("{}.OLD", n.to_string_lossy()))
            .unwrap_or_else(|| "backup.OLD".to_string());
        source
            .parent()
            .map(|p| p.join(&name))
            .unwrap_or_else(|| PathBuf::from(&name))
    };

    // Step 1: rename source → .OLD
    if let Err(e) = fs::rename(source, &old_path) {
        return SwapCompleteEvent {
            event_type: "swap_complete",
            old_path: old_path.to_string_lossy().into_owned(),
            new_path: cmd.source_path.clone(),
            error: Some(format!("Could not rename source to .OLD: {}", e)),
        };
    }

    // Step 2: rename target → source name
    if let Err(e) = fs::rename(target, source) {
        // Best-effort: try to undo step 1 so the user isn't left without their source.
        let _ = fs::rename(&old_path, source);
        return SwapCompleteEvent {
            event_type: "swap_complete",
            old_path: old_path.to_string_lossy().into_owned(),
            new_path: cmd.source_path.clone(),
            error: Some(format!(
                "Could not rename rationalized copy to source name: {}. \
                 The original has been restored.",
                e
            )),
        };
    }

    SwapCompleteEvent {
        event_type: "swap_complete",
        old_path: old_path.to_string_lossy().into_owned(),
        new_path: cmd.source_path.clone(),
        error: None,
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

    fn make_dir(parent: &Path, name: &str) -> PathBuf {
        let path = parent.join(name);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn make_file(parent: &Path, name: &str, content: &[u8]) {
        let path = parent.join(name);
        let mut f = fs::File::create(&path).unwrap();
        f.write_all(content).unwrap();
    }

    // ── civil_from_days ──────────────────────────────────────────────────

    #[test]
    fn test_epoch_is_1970_01_01() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
    }

    #[test]
    fn test_known_date() {
        // 2026-03-28 = 20540 days since epoch
        // Verified: 56 years (1970-2025) = 20454 days; + 31 (Jan) + 28 (Feb) + 27 (Mar 1-27) = 86
        let (y, m, d) = civil_from_days(20540);
        assert_eq!((y, m, d), (2026, 3, 28));
    }

    // ── scan_directory ───────────────────────────────────────────────────

    #[test]
    fn test_scan_empty_root() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        assert_eq!(folders.len(), 1); // root itself
        assert!(errors.is_empty());
        assert_eq!(folders[0].real_file_count, 0);
        assert_eq!(folders[0].child_folder_count, 0);
    }

    #[test]
    fn test_scan_counts_real_files_only() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        make_file(root, "photo.jpg", b"data");
        make_file(root, ".DS_Store", b"meta");
        make_file(root, "Thumbs.db", b"meta");
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        assert_eq!(folders[0].real_file_count, 1); // only photo.jpg
    }

    #[test]
    fn test_scan_depth_assignment() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let a = make_dir(root, "Alpha");
        make_dir(&a, "Beta");
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let depths: std::collections::HashMap<&str, usize> = folders
            .iter()
            .map(|f| (f.name.as_str(), f.depth))
            .collect();
        assert_eq!(depths[root.file_name().unwrap().to_str().unwrap()], 0);
        assert_eq!(depths["Alpha"], 1);
        assert_eq!(depths["Beta"], 2);
    }

    // ── generate_findings — empty_folder ─────────────────────────────────

    #[test]
    fn test_empty_folder_finding() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        make_dir(root, "Empty");
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let empty: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "empty_folder")
            .collect();
        assert_eq!(empty.len(), 1);
        assert_eq!(empty[0].display_name, "Empty");
        assert_eq!(empty[0].action, "remove");
    }

    #[test]
    fn test_nonempty_folder_not_flagged() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let sub = make_dir(root, "Photos");
        make_file(&sub, "photo.jpg", b"data");
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let empty: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "empty_folder")
            .collect();
        assert!(empty.is_empty());
    }

    #[test]
    fn test_root_never_flagged_as_empty() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // Root has no files and no subfolders
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let empty: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "empty_folder")
            .collect();
        assert!(empty.is_empty());
    }

    // ── generate_findings — excessive_nesting ─────────────────────────────

    #[test]
    fn test_excessive_nesting_flagged() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // Create a 6-level deep path
        let mut current = root.to_path_buf();
        for name in &["L1", "L2", "L3", "L4", "L5", "L6"] {
            current = make_dir(&current, name);
        }
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let nested: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "excessive_nesting")
            .collect();
        assert!(!nested.is_empty());
        assert_eq!(nested[0].display_name, "L6");
    }

    #[test]
    fn test_threshold_depth_not_flagged() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let mut current = root.to_path_buf();
        // Exactly threshold (5 levels deep)
        for name in &["L1", "L2", "L3", "L4", "L5"] {
            current = make_dir(&current, name);
        }
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let nested: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "excessive_nesting")
            .collect();
        assert!(nested.is_empty());
    }

    // ── generate_findings — naming_inconsistency ──────────────────────────

    #[test]
    fn test_naming_inconsistency_detected() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // 9 Title Case siblings + 1 snake_case outlier = 90% Title Case, meets threshold
        for name in &[
            "Alpha Photos", "Beta Videos", "Gamma Music", "Delta Docs",
            "Epsilon Notes", "Zeta Work", "Eta Finance", "Theta Archive", "Iota Books",
        ] {
            let d = make_dir(root, name);
            make_file(&d, "file.txt", b"x");
        }
        let outlier = make_dir(root, "kappa_misc");
        make_file(&outlier, "file.txt", b"x");

        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let naming: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "naming_inconsistency")
            .collect();
        assert_eq!(naming.len(), 1);
        assert_eq!(naming[0].display_name, "kappa_misc");
    }

    #[test]
    fn test_no_naming_finding_below_threshold() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // Only 2 siblings — below min_samples of 3, so no dominant convention
        for name in &["Alpha Photos", "beta_videos"] {
            let d = make_dir(root, name);
            make_file(&d, "file.txt", b"x");
        }
        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let naming: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "naming_inconsistency")
            .collect();
        assert!(naming.is_empty());
    }

    // ── cascade (R5) ─────────────────────────────────────────────────────

    #[test]
    fn test_cascade_parent_surfaced() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let parent = make_dir(root, "Old Projects");
        make_dir(&parent, "Archive"); // empty child — will be flagged

        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let empty: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "empty_folder")
            .collect();

        // Both Archive (direct) and Old Projects (cascade) should be findings
        let names: Vec<&str> = empty.iter().map(|f| f.display_name.as_str()).collect();
        assert!(names.contains(&"Archive"), "Archive not found in: {:?}", names);
        assert!(
            names.contains(&"Old Projects"),
            "Old Projects not found in: {:?}",
            names
        );

        // Old Projects should have triggered_by set
        let cascade = empty
            .iter()
            .find(|f| f.display_name == "Old Projects")
            .unwrap();
        assert!(cascade.triggered_by.is_some());
    }

    #[test]
    fn test_cascade_parent_not_surfaced_when_has_files() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let parent = make_dir(root, "Projects");
        make_dir(&parent, "Archive"); // empty child
        make_file(&parent, "notes.txt", b"data"); // parent has a real file

        let mut folders = Vec::new();
        let mut errors = Vec::new();
        scan_directory(root, root, 0, &mut folders, &mut errors);
        let findings = generate_findings(root, &folders);
        let empty: Vec<_> = findings
            .iter()
            .filter(|f| f.finding_type == "empty_folder")
            .collect();

        // Only Archive flagged; Projects has a real file so it won't become empty
        assert_eq!(empty.len(), 1);
        assert_eq!(empty[0].display_name, "Archive");
    }

    // ── execute_remove ────────────────────────────────────────────────────

    #[test]
    fn test_execute_remove_moves_to_quarantine() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let quarantine = TempDir::new().unwrap();

        let folder = make_dir(root, "OldStuff");
        let (outcome, error, dest_str) =
            execute_remove(&folder, root, quarantine.path());

        assert_eq!(outcome, "succeeded");
        assert!(error.is_none());
        assert!(!folder.exists());
        let dest = PathBuf::from(&dest_str);
        assert!(dest.exists());
    }

    #[test]
    fn test_execute_remove_missing_source_is_skipped() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let quarantine = TempDir::new().unwrap();
        let ghost = root.join("DoesNotExist");
        let (outcome, error, _) = execute_remove(&ghost, root, quarantine.path());
        assert_eq!(outcome, "skipped");
        assert!(error.is_some());
    }

    // ── execute_move ──────────────────────────────────────────────────────

    #[test]
    fn test_execute_move_renames_folder() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let src = make_dir(root, "old_name");
        let dest = root.join("New Name");
        let (outcome, error, _) = execute_move(&src, &dest);
        assert_eq!(outcome, "succeeded");
        assert!(error.is_none());
        assert!(!src.exists());
        assert!(dest.exists());
    }

    #[test]
    fn test_execute_move_conflict_fails() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // src and dest must be in different parent directories so the engine
        // treats this as a move (not a rename). Same-parent collisions are
        // auto-suffixed; cross-parent collisions are reported as conflicts.
        let src_dir = make_dir(root, "src_parent");
        let dest_dir = make_dir(root, "dest_parent");
        let src = make_dir(&src_dir, "folder");
        let dest = make_dir(&dest_dir, "folder"); // already exists in dest_parent
        let (outcome, error, _) = execute_move(&src, &dest);
        assert_eq!(outcome, "failed");
        assert!(error.is_some());
        assert!(src.exists()); // untouched
    }

    // ── build_target ──────────────────────────────────────────────────────

    #[test]
    fn test_build_target_mirrors_clean_tree() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let source = make_dir(root, "source");
        let target = root.join("target");
        make_dir(&source, "photos");
        make_dir(&source, "docs");

        let cmd = BuildCommand {
            command_type: "build".to_string(),
            source_path: source.to_string_lossy().into_owned(),
            target_path: target.to_string_lossy().into_owned(),
            session_id: "test".to_string(),
            actions: vec![],
            duplicate_removals: vec![],
        };
        let result = build_target(&cmd);
        assert!(result.error.is_none(), "{:?}", result.error);
        assert!(target.join("photos").exists());
        assert!(target.join("docs").exists());
        assert!(source.exists()); // source untouched
    }

    #[test]
    fn test_build_target_applies_rename() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let source = make_dir(root, "source");
        let target = root.join("target");
        // Use names that differ by more than case so macOS case-insensitive
        // filesystem doesn't conflate them.
        let old_dir = make_dir(&source, "photos-raw");

        let cmd = BuildCommand {
            command_type: "build".to_string(),
            source_path: source.to_string_lossy().into_owned(),
            target_path: target.to_string_lossy().into_owned(),
            session_id: "test".to_string(),
            actions: vec![ExecutionAction {
                finding_id: "f1".to_string(),
                action: "rename".to_string(),
                absolute_path: old_dir.to_string_lossy().into_owned(),
                absolute_destination: Some(
                    source.join("Photos").to_string_lossy().into_owned(),
                ),
            }],
            duplicate_removals: vec![],
        };
        let result = build_target(&cmd);
        assert!(result.error.is_none(), "{:?}", result.error);
        assert!(!target.join("photos-raw").exists()); // old name absent
        assert!(target.join("Photos").exists()); // new name present
        assert!(source.join("photos-raw").exists()); // source untouched
    }

    #[test]
    fn test_build_target_omits_removed_folder() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let source = make_dir(root, "source");
        let target = root.join("target");
        let keep = make_dir(&source, "keep");
        let remove = make_dir(&source, "remove_me");

        let cmd = BuildCommand {
            command_type: "build".to_string(),
            source_path: source.to_string_lossy().into_owned(),
            target_path: target.to_string_lossy().into_owned(),
            session_id: "test".to_string(),
            actions: vec![ExecutionAction {
                finding_id: "f1".to_string(),
                action: "remove".to_string(),
                absolute_path: remove.to_string_lossy().into_owned(),
                absolute_destination: None,
            }],
            duplicate_removals: vec![],
        };
        let result = build_target(&cmd);
        assert!(result.error.is_none(), "{:?}", result.error);
        assert!(target.join("keep").exists());
        assert!(!target.join("remove_me").exists()); // omitted
        assert_eq!(result.folders_omitted, 1);
        assert!(source.join("remove_me").exists()); // source untouched
        let _ = keep;
    }

    #[test]
    fn test_build_target_copies_files() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let source = make_dir(root, "source");
        let target = root.join("target");
        let subdir = make_dir(&source, "photos");
        fs::write(subdir.join("img.jpg"), b"fake jpeg").unwrap();

        let cmd = BuildCommand {
            command_type: "build".to_string(),
            source_path: source.to_string_lossy().into_owned(),
            target_path: target.to_string_lossy().into_owned(),
            session_id: "test".to_string(),
            actions: vec![],
            duplicate_removals: vec![],
        };
        let result = build_target(&cmd);
        assert!(result.error.is_none(), "{:?}", result.error);
        assert_eq!(result.files_copied, 1);
        assert!(target.join("photos").join("img.jpg").exists());
    }

    #[test]
    fn test_build_target_omits_duplicate_removals() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let source = make_dir(root, "source");
        let target = root.join("target");

        // Two copies of the same file in different folders.
        let photos = make_dir(&source, "Photos");
        let holidays = make_dir(&source, "Holidays");
        make_file(&photos, "IMG_0055.txt", b"vacation photo content");
        make_file(&holidays, "IMG_0055.txt", b"vacation photo content");

        // User chose to keep Photos/IMG_0055.txt; Holidays/IMG_0055.txt is a removal.
        let cmd = BuildCommand {
            command_type: "build".to_string(),
            source_path: source.to_string_lossy().into_owned(),
            target_path: target.to_string_lossy().into_owned(),
            session_id: "test".to_string(),
            actions: vec![],
            duplicate_removals: vec!["Holidays/IMG_0055.txt".to_string()],
        };
        let result = build_target(&cmd);
        assert!(result.error.is_none(), "{:?}", result.error);

        // Kept copy present in target.
        assert!(
            target.join("Photos").join("IMG_0055.txt").exists(),
            "kept copy should be in target"
        );
        // Removed copy absent from target.
        assert!(
            !target.join("Holidays").join("IMG_0055.txt").exists(),
            "duplicate removal should be absent from target"
        );
        // Source untouched.
        assert!(source.join("Holidays").join("IMG_0055.txt").exists());
    }

    #[test]
    fn test_build_target_refuses_existing_target() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let source = make_dir(root, "source");
        let target = make_dir(root, "target"); // already exists

        let cmd = BuildCommand {
            command_type: "build".to_string(),
            source_path: source.to_string_lossy().into_owned(),
            target_path: target.to_string_lossy().into_owned(),
            session_id: "test".to_string(),
            actions: vec![],
            duplicate_removals: vec![],
        };
        let result = build_target(&cmd);
        assert!(result.error.is_some());
    }

    // ── execute_swap ──────────────────────────────────────────────────────

    #[test]
    fn test_execute_swap_renames_both_dirs() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        let source = make_dir(root, "MyFolder");
        let target = make_dir(root, "MyFolder_rationalized");
        let old_path = root.join("MyFolder.OLD");

        let cmd = SwapCommand {
            command_type: "swap".to_string(),
            source_path: source.to_string_lossy().into_owned(),
            target_path: target.to_string_lossy().into_owned(),
        };
        let result = execute_swap(&cmd);
        assert!(result.error.is_none(), "{:?}", result.error);
        assert!(old_path.exists()); // source renamed to .OLD
        assert!(source.exists()); // target now at original source path
        assert!(!target.exists()); // rationalized copy renamed away
    }
}
