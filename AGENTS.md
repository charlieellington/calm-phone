# Working on Calm Phone

Calm Phone is an iPhone app built with SwiftUI and Apple's Screen Time APIs.
Start with [README.md](README.md) and [docs/colour.md](docs/colour.md).
Use `make help` for the commands; Xcode is required for native builds.

## Where to change things

- `Quiet/`: setup, PIN flow, status, settings, history and colour screens.
- `QuietShared/ApplePolicy.swift`: the single writer of system restrictions.
- `QuietMonitor/`: Device Activity callbacks for limits and access expiry.
- `QuietShieldConfig/` and `QuietShieldAction/`: blocked-app presentation.
- `QuietWidget/`: compatibility for retired widgets; normal icons open apps.
- `Packages/QuietCore/`: policy, timed grants, SQLite state and host tests.
- `scripts/colour_shortcuts.py`: optional native Colour Filters workflows.
- `docs/wallpapers/`: optional paper and evening Home Screen images.

There are five app/extension targets and two native test targets in
`Quiet.xcodeproj`; the shared scheme is `Quiet`. Internal `quiet` identifiers
may remain. Every user-facing app name is **Calm Phone**.

## Change apps, limits and home rows

People choose real app tokens in setup; a typed app name cannot identify an
Apple Screen Time token. `Policy.quotas` supplies the six default limit slots
and minutes. Update validation, setup and tests together when changing the
number of slots. `AppCatalog` retains old saved-identity metadata, not a
preselected personal app list. Home Screen rows use ordinary iOS app icons
and are arranged by the person on their phone. Ask what they want to keep
or limit before choosing a new policy.

## Preserve the controls

Keep PIN entry private. Require the PIN for temporary app access and policy
or PIN changes; early locking must remain available without it. Preserve
saved selections, limits, exhaustion, credentials and history on updates.
Never add a launch URL, widget or colour action that grants app access.
Keep display colour separate from Screen Time enforcement. Timed automatic
colour restoration is unavailable in this snapshot.

Keep phone data local: no accounts, analytics or network clients. Keep
signing configuration in ignored `Config/Signing.local.xcconfig`, and all
build logs/results under ignored `.build/`. Do not commit credentials,
device identifiers, live selection tokens or literal example PINs.

## Validation

Use two-space Swift indentation and the checked-in `.swift-format` rules.
Run `make lint-fix` after Swift edits, then `make check` for formatting, host
tests, Shortcut tests, process-store checks, static audits and unsigned
Debug/Release builds. `make test-ios` uses an installed iPhone simulator;
set `QUIET_SIMULATOR_ID` to select another available simulator. Native
results are saved under `.build/evidence/`.

Simulator and host checks cannot prove physical shielding, expiry while
the screen is locked, or automatic Colour Filters changes. Describe actual
phone observations separately and leave untested behaviour explicit.
