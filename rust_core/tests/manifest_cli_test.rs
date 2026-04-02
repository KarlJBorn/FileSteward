use serde_json::Value;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("test_corpus")
        .join("basic_scan")
}

fn rationalize_fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("test_corpus")
        .join(name)
}

/// Run `rust_core rationalize <path>` and parse the first NDJSON line that
/// has `"type": "findings"`. Progress lines (type=progress) are skipped.
fn run_rationalize(fixture: &str) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_rust_core"))
        .arg("rationalize")
        .arg(rationalize_fixture_path(fixture))
        .output()
        .expect("should run rust_core rationalize");

    assert!(
        output.status.success(),
        "expected success, stderr was: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if v["type"] == "findings" {
                return v;
            }
        }
    }
    panic!("no findings payload found in output:\n{}", stdout);
}

#[test]
fn manifest_cli_outputs_expected_fixture_shape() {
    let output = Command::new(env!("CARGO_BIN_EXE_rust_core"))
        .arg(fixture_path())
        .output()
        .expect("should run rust_core fixture scan");

    assert!(
        output.status.success(),
        "expected success, stderr was: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let manifest: Value =
        serde_json::from_slice(&output.stdout).expect("should parse manifest JSON");

    assert_eq!(manifest["exists"], true);
    assert_eq!(manifest["is_directory"], true);
    assert_eq!(manifest["total_directories"], 4);
    assert_eq!(manifest["total_files"], 3);

    let entries = manifest["entries"]
        .as_array()
        .expect("entries should be an array");

    let relative_paths: Vec<&str> = entries
        .iter()
        .map(|entry| {
            entry["relative_path"]
                .as_str()
                .expect("relative_path should be a string")
        })
        .collect();

    assert_eq!(
        relative_paths,
        vec![
            "archive",
            "archive/2024",
            "archive/2024/notes.md",
            "docs",
            "docs/readme.txt",
            "photos",
            "photos/cover.jpg",
        ]
    );

    assert_eq!(entries[0]["entry_type"], "directory");
    assert_eq!(entries[2]["entry_type"], "file");
    assert_eq!(entries[4]["size_bytes"], 27);
}

// ---------------------------------------------------------------------------
// Duplicate detection + ranker tests (rationalize mode, #82/#83)
// ---------------------------------------------------------------------------

fn duplicate_groups(fixture: &str) -> Vec<serde_json::Value> {
    let payload = run_rationalize(fixture);
    payload["duplicate_groups"]
        .as_array()
        .expect("duplicate_groups should be an array")
        .clone()
}

fn paths_of(group: &serde_json::Value) -> Vec<String> {
    group["paths"]
        .as_array()
        .expect("group should have a paths array")
        .iter()
        .map(|p| p.as_str().expect("path should be a string").to_string())
        .collect()
}

fn suggested_keep(group: &serde_json::Value) -> &str {
    group["suggested_keep"]
        .as_str()
        .expect("group should have suggested_keep")
}

#[test]
fn rationalize_detects_duplicate_pair() {
    let groups = duplicate_groups("rationalize_duplicates");
    // Should find exactly 2 groups: the IMG_0055 pair and the birthday three-way.
    assert_eq!(groups.len(), 2, "expected 2 duplicate groups, got: {:?}", groups);
}

#[test]
fn rationalize_duplicate_groups_contain_correct_paths() {
    let groups = duplicate_groups("rationalize_duplicates");

    let mut group_sets: Vec<Vec<String>> = groups.iter().map(|g| paths_of(g)).collect();
    group_sets.sort_by(|a, b| a[0].cmp(&b[0]));

    // IMG_0055 pair (2-way)
    assert_eq!(
        group_sets[0],
        vec!["Family/Photos/IMG_0055.txt", "Holidays/IMG_0055.txt"],
    );
    // birthday three-way
    assert_eq!(
        group_sets[1],
        vec!["Family/Photos/birthday.txt", "Temp/birthday_backup.txt", "Videos/birthday.txt"],
    );
}

#[test]
fn rationalize_unique_file_not_in_duplicate_groups() {
    let groups = duplicate_groups("rationalize_duplicates");
    let all_paths: Vec<String> = groups.iter().flat_map(|g| paths_of(g)).collect();
    assert!(
        !all_paths.iter().any(|p| p.ends_with("notes.txt")),
        "unique file should not appear in any duplicate group"
    );
}

#[test]
fn rationalize_no_duplicates_returns_empty_groups() {
    let groups = duplicate_groups("rationalize_clean");
    assert!(groups.is_empty(), "expected no duplicate groups, got: {:?}", groups);
}

// — Ranker tests (#83) —

#[test]
fn ranker_penalizes_junk_folder_temp() {
    // birthday_backup.txt lives in Temp/ — should NOT be the suggested keep.
    let groups = duplicate_groups("rationalize_duplicates");
    let birthday_group = groups
        .iter()
        .find(|g| paths_of(g).contains(&"Temp/birthday_backup.txt".to_string()))
        .expect("birthday group should exist");
    assert_ne!(
        suggested_keep(birthday_group),
        "Temp/birthday_backup.txt",
        "file in Temp/ should not be the suggested keep"
    );
}

#[test]
fn ranker_penalizes_copy_artifact_in_filename() {
    // birthday_backup.txt has "_backup" artifact — should be penalized.
    let groups = duplicate_groups("rationalize_duplicates");
    let birthday_group = groups
        .iter()
        .find(|g| paths_of(g).contains(&"Temp/birthday_backup.txt".to_string()))
        .expect("birthday group should exist");
    assert_ne!(
        suggested_keep(birthday_group),
        "Temp/birthday_backup.txt",
        "copy-artifact file should not be the suggested keep"
    );
}

#[test]
fn ranker_suggested_keep_is_not_ambiguous_for_birthday_group() {
    // The birthday group has a clear winner (Videos/birthday.txt: depth 1, no junk, no artifact).
    let groups = duplicate_groups("rationalize_duplicates");
    let birthday_group = groups
        .iter()
        .find(|g| paths_of(g).contains(&"Videos/birthday.txt".to_string()))
        .expect("birthday group should exist");
    assert_eq!(
        birthday_group["ambiguous"], false,
        "birthday group should not be ambiguous"
    );
}

#[test]
fn ranker_each_group_has_required_fields() {
    let groups = duplicate_groups("rationalize_duplicates");
    for group in &groups {
        assert!(group["paths"].is_array(), "group missing paths");
        assert!(group["suggested_keep"].is_string(), "group missing suggested_keep");
        assert!(group["reasons"].is_array(), "group missing reasons");
        assert!(group["ambiguous"].is_boolean(), "group missing ambiguous");
        // suggested_keep must be one of the paths
        let keep = suggested_keep(group);
        assert!(
            paths_of(group).contains(&keep.to_string()),
            "suggested_keep '{}' is not in paths {:?}",
            keep,
            paths_of(group)
        );
    }
}

// ---------------------------------------------------------------------------
// Consolidate CLI tests (#95, #101)
// ---------------------------------------------------------------------------

fn consolidate_fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("test_corpus")
        .join("consolidate_basic")
        .join(name)
}

/// Run `rust_core consolidate` with a JSON command on stdin.
/// Returns the `consolidate_scan_complete` line as a Value.
fn run_consolidate(primary: &str, secondaries: &[&str]) -> Value {
    let cmd = serde_json::json!({
        "command": "consolidate_scan",
        "primary": primary,
        "secondaries": secondaries,
    });

    let mut child = Command::new(env!("CARGO_BIN_EXE_rust_core"))
        .arg("consolidate")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("should spawn rust_core consolidate");

    child
        .stdin
        .take()
        .unwrap()
        .write_all(cmd.to_string().as_bytes())
        .unwrap();

    let output = child.wait_with_output().expect("should complete");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if v["type"] == "consolidate_scan_complete" {
                return v;
            }
        }
    }
    panic!("no consolidate_scan_complete event in output:\n{}", stdout);
}

fn unique_paths_for(result: &Value, secondary_index: usize) -> Vec<String> {
    result["secondaries"][secondary_index]["unique_files"]
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .map(|f| f["relative_path"].as_str().unwrap_or("").to_string())
        .collect()
}

#[test]
fn consolidate_shared_file_not_in_unique_list() {
    // family.txt has the same content (hash) in primary, secondary_a, and secondary_b.
    // It must not appear in either secondary's unique_files list.
    let primary = consolidate_fixture("primary");
    let sec_a = consolidate_fixture("secondary_a");
    let sec_b = consolidate_fixture("secondary_b");

    let result = run_consolidate(
        primary.to_str().unwrap(),
        &[sec_a.to_str().unwrap(), sec_b.to_str().unwrap()],
    );

    let paths_a = unique_paths_for(&result, 0);
    let paths_b = unique_paths_for(&result, 1);

    assert!(
        !paths_a.iter().any(|p| p.contains("family")),
        "family.txt should not be unique to secondary_a: {:?}", paths_a
    );
    assert!(
        !paths_b.iter().any(|p| p.contains("family")),
        "family.txt should not be unique to secondary_b: {:?}", paths_b
    );
}

#[test]
fn consolidate_unique_files_per_secondary() {
    // secondary_a has birthday.txt and letter.txt not in primary.
    // secondary_b has reunion.txt and archive.bin not in primary.
    let primary = consolidate_fixture("primary");
    let sec_a = consolidate_fixture("secondary_a");
    let sec_b = consolidate_fixture("secondary_b");

    let result = run_consolidate(
        primary.to_str().unwrap(),
        &[sec_a.to_str().unwrap(), sec_b.to_str().unwrap()],
    );

    let paths_a = unique_paths_for(&result, 0);
    let paths_b = unique_paths_for(&result, 1);

    assert!(
        paths_a.iter().any(|p| p.contains("birthday")),
        "birthday.txt should be unique to secondary_a: {:?}", paths_a
    );
    assert!(
        paths_a.iter().any(|p| p.contains("letter")),
        "letter.txt should be unique to secondary_a: {:?}", paths_a
    );
    assert!(
        paths_b.iter().any(|p| p.contains("reunion")),
        "reunion.txt should be unique to secondary_b: {:?}", paths_b
    );
    assert!(
        paths_b.iter().any(|p| p.contains("archive")),
        "archive.bin should be unique to secondary_b: {:?}", paths_b
    );
}

#[test]
fn consolidate_primary_only_files_ignored() {
    // vacation.txt and tax_2014.txt are only in primary — they should not
    // appear in either secondary's unique list (the diff is secondary → primary).
    let primary = consolidate_fixture("primary");
    let sec_a = consolidate_fixture("secondary_a");

    let result = run_consolidate(
        primary.to_str().unwrap(),
        &[sec_a.to_str().unwrap()],
    );

    let paths_a = unique_paths_for(&result, 0);
    assert!(
        !paths_a.iter().any(|p| p.contains("vacation")),
        "vacation.txt is primary-only and should not appear: {:?}", paths_a
    );
    assert!(
        !paths_a.iter().any(|p| p.contains("tax")),
        "tax_2014.txt is primary-only and should not appear: {:?}", paths_a
    );
}

#[test]
fn consolidate_binary_blob_detected_as_unique() {
    // archive.bin is an opaque binary file unique to secondary_b.
    // The engine hashes it as bytes — it should appear as unique.
    let primary = consolidate_fixture("primary");
    let sec_b = consolidate_fixture("secondary_b");

    let result = run_consolidate(
        primary.to_str().unwrap(),
        &[sec_b.to_str().unwrap()],
    );

    let paths_b = unique_paths_for(&result, 0);
    assert!(
        paths_b.iter().any(|p| p.contains("archive")),
        "archive.bin should be detected as unique to secondary_b: {:?}", paths_b
    );
}

#[test]
fn consolidate_result_has_required_fields() {
    let primary = consolidate_fixture("primary");
    let sec_a = consolidate_fixture("secondary_a");

    let result = run_consolidate(
        primary.to_str().unwrap(),
        &[sec_a.to_str().unwrap()],
    );

    assert_eq!(result["type"], "consolidate_scan_complete");
    assert!(result["primary"].is_string(), "primary field missing");
    assert!(result["secondaries"].is_array(), "secondaries field missing");

    let sec = &result["secondaries"][0];
    assert!(sec["path"].is_string(), "secondary path missing");
    assert!(sec["unique_files"].is_array(), "unique_files missing");

    let files = sec["unique_files"].as_array().unwrap();
    if !files.is_empty() {
        assert!(files[0]["relative_path"].is_string(), "relative_path missing");
        assert!(files[0]["size_bytes"].is_number(), "size_bytes missing");
    }
}

// ---------------------------------------------------------------------------
// Registry tests (#96)
// ---------------------------------------------------------------------------

/// Run a consolidate_scan with an explicit session_id and an isolated registry.
/// Returns (scan result Value, registry path).
fn run_consolidate_with_session(
    primary: &str,
    secondaries: &[&str],
    session_id: &str,
    target: &str,
    registry_path: &str,
) -> Value {
    let cmd = serde_json::json!({
        "command": "consolidate_scan",
        "primary": primary,
        "secondaries": secondaries,
        "session_id": session_id,
        "target": target,
    });

    let mut child = Command::new(env!("CARGO_BIN_EXE_rust_core"))
        .arg("consolidate")
        .env("FILESTEWARD_REGISTRY_PATH", registry_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("should spawn rust_core consolidate");

    child.stdin.take().unwrap()
        .write_all(cmd.to_string().as_bytes())
        .unwrap();

    let output = child.wait_with_output().expect("should complete");
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if v["type"] == "consolidate_scan_complete" {
                return v;
            }
        }
    }
    panic!("no consolidate_scan_complete in output:\n{}", stdout);
}

fn run_consolidate_finalize(session_id: &str, registry_path: &str) -> Value {
    let cmd = serde_json::json!({
        "command": "consolidate_finalize",
        "session_id": session_id,
    });

    let mut child = Command::new(env!("CARGO_BIN_EXE_rust_core"))
        .arg("consolidate")
        .env("FILESTEWARD_REGISTRY_PATH", registry_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("should spawn rust_core consolidate");

    child.stdin.take().unwrap()
        .write_all(cmd.to_string().as_bytes())
        .unwrap();

    let output = child.wait_with_output().expect("should complete");
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if v["type"] == "consolidate_finalize_complete" {
                return v;
            }
        }
    }
    panic!("no consolidate_finalize_complete in output:\n{}", stdout);
}

fn read_registry_at(path: &str) -> Value {
    let content = std::fs::read_to_string(path)
        .expect("sessions.json should exist after a scan");
    serde_json::from_str(&content).expect("sessions.json should be valid JSON")
}

#[test]
fn registry_scan_creates_session() {
    let registry = std::env::temp_dir().join("fs_test_registry_scan_creates.json");
    let registry_str = registry.to_str().unwrap();
    let session_id = "test-registry-scan-creates";
    let primary = consolidate_fixture("primary");
    let sec_a = consolidate_fixture("secondary_a");

    run_consolidate_with_session(
        primary.to_str().unwrap(),
        &[sec_a.to_str().unwrap()],
        session_id,
        "/tmp/test_consolidated",
        registry_str,
    );

    let reg = read_registry_at(registry_str);
    let sessions = reg["sessions"].as_array().expect("sessions array");
    let session = sessions.iter().find(|s| s["id"] == session_id)
        .expect("session should be in registry");

    assert_eq!(session["status"], "in_progress");
    assert_eq!(session["primary"], primary.to_str().unwrap());
}

#[test]
fn registry_finalize_updates_status() {
    let registry = std::env::temp_dir().join("fs_test_registry_finalize.json");
    let registry_str = registry.to_str().unwrap();
    let session_id = "test-registry-finalize";
    let primary = consolidate_fixture("primary");
    let sec_a = consolidate_fixture("secondary_a");

    run_consolidate_with_session(
        primary.to_str().unwrap(),
        &[sec_a.to_str().unwrap()],
        session_id,
        "/tmp/test_consolidated_finalize",
        registry_str,
    );

    let result = run_consolidate_finalize(session_id, registry_str);
    assert_eq!(result["type"], "consolidate_finalize_complete");
    assert_eq!(result["session_id"], session_id);

    let reg = read_registry_at(registry_str);
    let sessions = reg["sessions"].as_array().expect("sessions array");
    let session = sessions.iter().find(|s| s["id"] == session_id)
        .expect("session should be in registry");

    assert_eq!(session["status"], "finalized");
}
