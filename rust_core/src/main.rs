use serde::Serialize;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Serialize)]
struct ManifestEntry {
    relative_path: String,
    entry_type: String,
    size_bytes: Option<u64>,
}

#[derive(Serialize)]
struct ManifestResult {
    selected_folder: String,
    exists: bool,
    is_directory: bool,
    total_directories: usize,
    total_files: usize,
    entries: Vec<ManifestEntry>,
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

    let result = ManifestResult {
        selected_folder: folder_path.to_string(),
        exists,
        is_directory,
        total_directories,
        total_files,
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

            entries.push(ManifestEntry {
                relative_path,
                entry_type: "file".to_string(),
                size_bytes: Some(metadata.len()),
            });
        } else {
            entries.push(ManifestEntry {
                relative_path,
                entry_type: "other".to_string(),
                size_bytes: None,
            });
        }
    }

    Ok(())
}