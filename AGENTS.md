# Working on Calm Phone

Calm Phone is an iPhone app built with SwiftUI and Apple's Screen Time APIs.
Start with [README.md](README.md), [docs/remote-unlock.md](docs/remote-unlock.md)
and [docs/colour.md](docs/colour.md).
Use `make help` for the commands; Xcode is required for native builds.

## Where to change things

- `Quiet/`: setup, PIN flow, status, settings, history, colour and remote screens.
- `Quiet/RemoteModel.swift` and `RemoteStores.swift`: URL handling and private Keychain records.
- `Packages/QuietCore/Sources/QuietCore/RemoteUnlock.swift`: c2 pairing and signed u1 capabilities.
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

Keep PIN entry private. Temporary app access needs either a current PIN
capability or an authenticated single-use remote-link capability. Both go
through `QuietModel.openLease` and the existing grant coordinator; only an
activated lease is a successful unlock. Policy/PIN changes still need PIN
authorization. Adding/removing remotes and helper connections stay PIN-free;
early locking remains available without authorization. Preserve selections,
limits, exhaustion, credentials and history on updates.

Only the strict c2/u1 parsers may accept connect/unlock URLs. Do not add
unauthenticated URL, widget or colour grants. Preserve authoritative storage
reads, persisted nonce/freshness protection, credential generations, receiver
midnight calculation, visible cold/warm navigation outcomes and fail-closed
writes. Names identify people for display, never phone identities. Connection
links contain bearer pairing keys: keep raw links out of logs/screenshots.
No accounts, push, unlock backend or per-app remote grants.
Keep display colour separate from Screen Time enforcement. Timed automatic
colour restoration is unavailable in this snapshot.

Keep selections, PIN and history local. Links are shared through the chosen
messaging app; verification needs no network client. No accounts or analytics. Keep
signing configuration in ignored `Config/Signing.local.xcconfig`, and all
build logs/results under ignored `.build/`. Do not commit credentials,
device identifiers, live selection tokens or literal example PINs.

## Validation

Use two-space Swift indentation and the checked-in `.swift-format` rules.
Run `make lint-fix` after Swift edits, then `make check` for formatting, host
tests, Shortcut tests, process-store checks, static audits and unsigned
Debug/Release builds. `make test-ios` uses an installed iPhone simulator;
set `QUIET_SIMULATOR_ID` to select another available simulator. Native
results are saved under `.build/evidence/`. `make test-ui` runs the actual
navigation/accessibility lane. The public macOS workflow checks anonymous
shallow clones, `make check`, migration and both simulator lanes. Retain the
frozen public build-6 schemas under `scripts/fixtures/build6/`; never depend on
private Git history or remove upgrade coverage. Only the isolated real-Keychain
write’s diagnosed `errSecMissingEntitlement` (-34018) may skip; report it
separately from signed persistence. Keep fixtures synthetic and audit artifacts
before publishing them.

Simulator and host checks cannot prove physical shielding, expiry while
the screen is locked, or automatic Colour Filters changes. Describe actual
phone observations separately and leave untested behaviour explicit.
