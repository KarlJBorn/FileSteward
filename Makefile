.PHONY: rust-build flutter-run dev-status-controller test check

rust-build:
	cargo build --manifest-path rust_core/Cargo.toml

flutter-run:
	flutter run -d macos

dev-status-controller:
	dart run tool/dev_status_controller.dart

test:
	flutter test

check: rust-build test
