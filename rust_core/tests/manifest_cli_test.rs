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
// Duplicate detection tests (rationalize mode, #82)
// ---------------------------------------------------------------------------

#[test]
fn rationalize_detects_duplicate_pair() {
    let payload = run_rationalize("rationalize_duplicates");
    let groups = payload["duplicate_groups"]
        .as_array()
        .expect("duplicate_groups should be an array");

    // Should find exactly 2 groups: the IMG_0055 pair and the birthday three-way.
    assert_eq!(groups.len(), 2, "expected 2 duplicate groups, got: {:?}", groups);
}

#[test]
fn rationalize_duplicate_groups_contain_correct_paths() {
    let payload = run_rationalize("rationalize_duplicates");
    let groups = payload["duplicate_groups"]
        .as_array()
        .expect("duplicate_groups should be an array");

    // Collect all groups as sorted Vec<Vec<String>> for stable comparison.
    let mut group_sets: Vec<Vec<String>> = groups
        .iter()
        .map(|g| {
            let mut paths: Vec<String> = g
                .as_array()
                .expect("each group should be an array")
                .iter()
                .map(|p| p.as_str().expect("path should be a string").to_string())
                .collect();
            paths.sort();
            paths
        })
        .collect();
    group_sets.sort_by(|a, b| a[0].cmp(&b[0]));

    // IMG_0055 pair (2-way duplicate)
    assert_eq!(
        group_sets[0],
        vec!["Family/Photos/IMG_0055.jpg", "Holidays/IMG_0055.jpg"],
        "unexpected paths in IMG_0055 duplicate group"
    );

    // birthday three-way duplicate
    assert_eq!(
        group_sets[1],
        vec![
            "Family/Photos/birthday.mp4",
            "Temp/birthday_backup.mp4",
            "Videos/birthday.mp4",
        ],
        "unexpected paths in birthday duplicate group"
    );
}

#[test]
fn rationalize_unique_file_not_in_duplicate_groups() {
    let payload = run_rationalize("rationalize_duplicates");
    let groups = payload["duplicate_groups"]
        .as_array()
        .expect("duplicate_groups should be an array");

    let all_paths: Vec<&str> = groups
        .iter()
        .flat_map(|g| g.as_array().unwrap())
        .map(|p| p.as_str().unwrap())
        .collect();

    assert!(
        !all_paths.contains(&"Family/Photos/notes.txt"),
        "unique file should not appear in any duplicate group"
    );
}

#[test]
fn rationalize_no_duplicates_returns_empty_groups() {
    // rationalize_clean has three files with distinct content — no duplicates.
    let payload = run_rationalize("rationalize_clean");
    let groups = payload["duplicate_groups"]
        .as_array()
        .expect("duplicate_groups should be an array");
    assert!(
        groups.is_empty(),
        "expected no duplicate groups in clean fixture, got: {:?}",
        groups
    );
}
