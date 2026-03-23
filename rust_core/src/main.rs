use serde::Serialize;
use std::env;
use std::fs;
use std::path::Path;

#[derive(Serialize)]
struct ChildEntry {
    name: String,
    entry_type: String,
}

#[derive(Serialize)]
struct FolderInspectionResult {
    selected_folder: String,
    exists: bool,
    is_directory: bool,
    direct_child_entries: usize,
    children: Vec<ChildEntry>,
}

fn main() {
    // Read command-line arguments.
    // args[0] is the executable name, so we expect the folder path in args[1].
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("No folder path was provided.");
        std::process::exit(1);
    }

    let folder_path = &args[1];
    let path = Path::new(folder_path);

    let exists = path.exists();
    let is_directory = path.is_dir();

    // Build up a list of direct children only.
    // We are still not scanning recursively.
    let mut children: Vec<ChildEntry> = Vec::new();

    if exists && is_directory {
        match fs::read_dir(path) {
            Ok(entries) => {
                for entry_result in entries {
                    match entry_result {
                        Ok(entry) => {
                            let file_name = entry.file_name().to_string_lossy().to_string();
                            let entry_path = entry.path();

                            let entry_type = if entry_path.is_dir() {
                                "directory".to_string()
                            } else if entry_path.is_file() {
                                "file".to_string()
                            } else {
                                "other".to_string()
                            };

                            children.push(ChildEntry {
                                name: file_name,
                                entry_type,
                            });
                        }
                        Err(err) => {
                            eprintln!("Failed to read a directory entry: {}", err);
                            std::process::exit(1);
                        }
                    }
                }
            }
            Err(err) => {
                eprintln!("Failed to read directory: {}", err);
                std::process::exit(1);
            }
        }
    }

    // Sort children by name so the output is stable and predictable.
    children.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    let result = FolderInspectionResult {
        selected_folder: folder_path.to_string(),
        exists,
        is_directory,
        direct_child_entries: children.len(),
        children,
    };

    // Print JSON to stdout so Flutter can parse it.
    match serde_json::to_string_pretty(&result) {
        Ok(json) => println!("{}", json),
        Err(err) => {
            eprintln!("Failed to serialize JSON: {}", err);
            std::process::exit(1);
        }
    }
}