use hex;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Serialize)]
struct ManifestEntry {
    relative_path: String,
    entry_type: String,
    size_bytes: Option<u64>,
    sha256: Option<String>,
}

#[derive(Serialize)]
struct ManifestResult {
    selected_folder: String,
    exists: bool,
    is_directory: bool,
    total_directories: usize,
    total_files: usize,
    entries: Vec<ManifestEntry>,
    duplicate_groups: Vec<Vec<String>>,
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

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("No folder path was provided.");
        std::process::exit(1);
    }

    let folder_path = &args[1];
    let root_path = Path::new(folder_path);

    let exists = root_path.exists();
    let is_directory = root_path.is_dir();

    let mut entries: Vec<ManifestEntry> = Vec::new();
    let mut total_directories: usize = 0;
    let mut total_files: usize = 0;

    if exists && is_directory {
        if let Err(err) = walk_directory(
            root_path,
            root_path,
            &mut entries,
            &mut total_directories,
            &mut total_files,
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

    match serde_json::to_string_pretty(&result) {
        Ok(json) => println!("{}", json),
        Err(err) => {
            eprintln!("Failed to serialize JSON: {}", err);
            std::process::exit(1);
        }
    }
}

fn walk_directory(
    root_path: &Path,
    current_path: &Path,
    entries: &mut Vec<ManifestEntry>,
    total_directories: &mut usize,
    total_files: &mut usize,
) -> Result<(), String> {
    let read_dir = fs::read_dir(current_path).map_err(|err| err.to_string())?;

    for entry_result in read_dir {
        let entry = entry_result.map_err(|err| err.to_string())?;
        let entry_path: PathBuf = entry.path();
        let metadata = entry.metadata().map_err(|err| err.to_string())?;

        let relative_path = entry_path
            .strip_prefix(root_path)
            .map_err(|err| err.to_string())?
            .to_string_lossy()
            .to_string();

        if metadata.is_dir() {
            *total_directories += 1;

            entries.push(ManifestEntry {
                relative_path,
                entry_type: "directory".to_string(),
                size_bytes: None,
                sha256: None,
            });

            walk_directory(
                root_path,
                &entry_path,
                entries,
                total_directories,
                total_files,
            )?;
        } else if metadata.is_file() {
            *total_files += 1;
            let sha256 = hash_file(&entry_path);

            entries.push(ManifestEntry {
                relative_path,
                entry_type: "file".to_string(),
                size_bytes: Some(metadata.len()),
                sha256,
            });
        } else {
            entries.push(ManifestEntry {
                relative_path,
                entry_type: "other".to_string(),
                size_bytes: None,
                sha256: None,
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

    // --- build_duplicate_groups ---

    #[test]
    fn test_duplicate_groups_empty_input() {
        assert!(build_duplicate_groups(&[]).is_empty());
    }

    #[test]
    fn test_duplicate_groups_no_duplicates() {
        let entries = vec![
            ManifestEntry {
                relative_path: "a.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("aaaa".into()),
            },
            ManifestEntry {
                relative_path: "b.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("bbbb".into()),
            },
        ];
        assert!(build_duplicate_groups(&entries).is_empty());
    }

    #[test]
    fn test_duplicate_groups_detects_pair() {
        let entries = vec![
            ManifestEntry {
                relative_path: "a.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
            ManifestEntry {
                relative_path: "b.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
            ManifestEntry {
                relative_path: "c.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("different".into()),
            },
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0], vec!["a.txt", "b.txt"]);
    }

    #[test]
    fn test_duplicate_groups_detects_three_way_group() {
        let entries = vec![
            ManifestEntry {
                relative_path: "a.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
            ManifestEntry {
                relative_path: "b.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
            ManifestEntry {
                relative_path: "c.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0], vec!["a.txt", "b.txt", "c.txt"]);
    }

    #[test]
    fn test_duplicate_groups_two_independent_groups() {
        let entries = vec![
            ManifestEntry {
                relative_path: "a.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("hash_x".into()),
            },
            ManifestEntry {
                relative_path: "b.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("hash_x".into()),
            },
            ManifestEntry {
                relative_path: "c.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("hash_y".into()),
            },
            ManifestEntry {
                relative_path: "d.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("hash_y".into()),
            },
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0], vec!["a.txt", "b.txt"]);
        assert_eq!(groups[1], vec!["c.txt", "d.txt"]);
    }

    #[test]
    fn test_duplicate_groups_ignores_directories() {
        let entries = vec![
            ManifestEntry {
                relative_path: "dir_a".into(),
                entry_type: "directory".into(),
                size_bytes: None,
                sha256: None,
            },
            ManifestEntry {
                relative_path: "a.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
            ManifestEntry {
                relative_path: "b.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
        ];
        let groups = build_duplicate_groups(&entries);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0], vec!["a.txt", "b.txt"]);
    }

    #[test]
    fn test_duplicate_groups_skips_file_with_no_hash() {
        // A file whose hash is None (e.g. unreadable) must not crash or pollute groups.
        let entries = vec![
            ManifestEntry {
                relative_path: "a.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: Some("same".into()),
            },
            ManifestEntry {
                relative_path: "b.txt".into(),
                entry_type: "file".into(),
                size_bytes: Some(5),
                sha256: None,
            },
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

        walk_directory(
            &corpus_path,
            &corpus_path,
            &mut entries,
            &mut total_dirs,
            &mut total_files,
        )
        .unwrap();

        assert_eq!(total_files, 4, "Fixture should have exactly 4 files");
        assert_eq!(total_dirs, 1, "Fixture should have exactly 1 subdirectory");

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
}
