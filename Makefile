.PHONY: rust-build flutter-run test check

rust-build:
	cargo build --manifest-path rust_core/Cargo.toml

flutter-run:
	flutter run -d macos

test:
	flutter test

check: rust-build test
