# FileSteward

I have a pile of backup drives accumulated over the years — external hard drives, old Time Machine volumes, USB sticks — each a partial snapshot of files from different points in time. Every tool I found was either a bulk-delete utility (too dangerous) or a simple duplicate finder (too narrow). None of them helped me reason carefully about what to keep, what was redundant, and what was safe to remove.

So I built FileSteward.

## What it does

FileSteward is a macOS desktop app that helps you rationalize consolidated backup disks. It finds duplicate files, classifies what's there, and gives you the information you need to make confident decisions — without ever taking destructive action without your explicit approval.

The design principle: **analyze and recommend, never delete by default.**

## Why I built it this way

This project is also a learning exercise. I spent years as a software development manager, working with and leading engineering teams. I wanted to experience firsthand what AI-assisted development feels like from the builder's seat — not just as someone reviewing it.

I'm using Claude as a development partner, applying the same software engineering practices I've always believed in: clear architecture, tested code, incremental iteration, and a clean Git history. The goal is to build something genuinely useful while developing real competence as a developer.

## Current state (Iteration 1)

- Recursively scans any folder and builds a full file manifest
- SHA-256 hashes every file and identifies exact duplicates
- Groups duplicate files and surfaces them clearly in the UI
- Exports results as structured JSON
- 16 Rust unit + integration tests; 8 Flutter tests; CI on every PR

## Architecture

**Stack:** Flutter/Dart (UI) + Rust (file engine), communicating over JSON on stdout.

```
User picks folder → Flutter spawns Rust binary → Rust walks + hashes → JSON → Flutter renders
```

- [`lib/main.dart`](lib/main.dart) — UI and app state
- [`lib/manifest_models.dart`](lib/manifest_models.dart) — data models and JSON parsing
- [`lib/manifest_service.dart`](lib/manifest_service.dart) — spawns the Rust binary, parses output
- [`rust_core/src/main.rs`](rust_core/src/main.rs) — recursive walker, SHA-256 hashing, duplicate detection

## Running it

**Prerequisites:** Flutter, Rust/Cargo, macOS.

```sh
# 1. Build the Rust engine (required before running Flutter)
make rust-build

# 2. Run the app
make flutter-run

# 3. Run all tests
make check
```

## Roadmap

| Iteration | Focus |
|-----------|-------|
| ✅ 1 | CLI engine, manifest, SHA-256 hashing, duplicate detection |
| 2 | Full desktop UI, scan progress, quarantine workflow, export |
| 3 | Rules engine, similarity detection, undo/audit log |
| 4 | iPad/iPhone review client |
| 5 | Performance tuning, visual topology, recommendation engine |
