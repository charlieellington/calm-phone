.DEFAULT_GOAL := help
.PHONY: help lint lint-fix test test-shortcuts test-policy test-integration test-ios test-ui build build-ios check audit-bypasses audit-signing audit-publication assets
SWIFT_PATHS := Quiet QuietShared QuietMonitor QuietShieldConfig QuietShieldAction QuietWidget QuietTests QuietUITests Packages/QuietCore/Sources Packages/QuietCore/Tests Packages/QuietCore/Package.swift scripts/make-assets.swift
help:
	@echo 'Calm Phone: lint lint-fix test test-shortcuts test-policy test-integration test-ios test-ui build build-ios check audit-bypasses audit-signing audit-publication assets'
lint:
	xcrun swift-format lint --strict --recursive $(SWIFT_PATHS)
lint-fix:
	xcrun swift-format format --in-place --recursive $(SWIFT_PATHS)
test:
	swift test --package-path Packages/QuietCore
test-shortcuts:
	python3 scripts/test-colour-shortcuts.py
test-policy:
	swift test --package-path Packages/QuietCore --filter PolicyTests
test-integration:
	swift test --package-path Packages/QuietCore --filter IntegrationTests
	python3 scripts/test-process-store.py
test-ios:
	python3 scripts/native-check.py test
test-ui:
	python3 scripts/native-check.py ui
build:
	python3 scripts/native-check.py debug
build-ios:
	python3 scripts/native-check.py release
audit-bypasses:
	python3 scripts/audit.py bypass
audit-signing:
	python3 scripts/audit.py signing
audit-publication:
	python3 scripts/audit-publication.py
assets:
	swift scripts/make-assets.swift
check: lint test test-shortcuts test-integration audit-bypasses audit-signing audit-publication build build-ios
