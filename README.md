# FileSteward

FileSteward is a macOS-first Flutter + Rust prototype for safely inspecting a
folder tree and building a deterministic manifest for human review.

## Current Prototype

The app can:

- let the user choose a folder in Flutter
- invoke a Rust executable with that folder path
- build a recursive manifest in Rust
- return JSON to Flutter
- display counts and entries in the desktop UI

The current prototype does not:

- modify files
- hash files
- use AI
- package the Rust executable into the app bundle

## Architecture

- Flutter UI in [lib/main.dart](lib/main.dart)
- AgentBoard status output in [lib/agent_board_status_writer.dart](lib/agent_board_status_writer.dart)
- Rust manifest builder in [rust_core/src/main.rs](rust_core/src/main.rs)
- JSON over stdout/stderr as the integration boundary

This keeps the development flow simple and easy to inspect while the project is
still in the learning/prototype phase.

## macOS Development Flow

1. Build the Rust binary:

   ```sh
   make rust-build
   ```

2. Run the Flutter macOS app:

   ```sh
   make flutter-run
   ```

   To monitor FileSteward in AgentBoard at the same time:

   ```sh
   FILESTEWARD_AGENT_BOARD_DIR=~/Development/projects/FileSteward/dev_status make flutter-run
   ```

3. In the app, choose a folder and click `Build Manifest`.

The Flutter app looks for the Rust executable in:

- `FILESTEWARD_RUST_BINARY` if set
- `rust_core/target/debug/rust_core`
- a small set of nearby relative fallback paths used during local development

## AgentBoard Integration

Use a dedicated development status source for AgentBoard, separate from FileSteward runtime app behavior:

```sh
~/Development/projects/FileSteward/dev_status
```

That folder contains:

- `current_run.json`
- `work_log.jsonl`
- `commands.jsonl`
- `command_receipts.jsonl`

Development agents can write those files directly, and AgentBoard can point at that folder while FileSteward development is in progress.

Supported AgentBoard actions:

- `Approve`
- `Retry`
- `Request Checkpoint`

To make those actions update `dev_status/`, run the local controller in a separate terminal:

```sh
make dev-status-controller
```

## Checks

Run the current automated check with:

```sh
make test
```

GitHub Actions now runs the same Rust and Flutter test commands on `push` and
`pull_request` using [ci.yml](.github/workflows/ci.yml).

## Notes

- Debug macOS entitlements currently disable the app sandbox to keep the
  prototype workflow simple during development.
- Release entitlements are more restrictive and only allow read-only access to
  user-selected files.
- During development, FileSteward now writes AgentBoard-compatible snapshot and
  event files to `agent_board_status/` by default.
