use serde_json::Value;
use std::path::PathBuf;
use std::process::Command;

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
