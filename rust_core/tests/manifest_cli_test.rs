use serde_json::Value;
use std::path::PathBuf;
use std::process::Command;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("test_corpus")
        .join("basic_scan")
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
