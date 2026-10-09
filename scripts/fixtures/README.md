The Colour Filters setter fixture preserves the native `operation: turn`
with Boolean `state`, as saved by Apple's Shortcuts editor. It contains no
app, signing or device metadata. Enum-name strings and integer states are
rejected by the generator's regression tests. Actual display changes and
automation execution still require the phone test in `docs/colour.md`.


`build6/` freezes the public build-6 serialization types and SQLite writer
from public revision `2e04a43e287cd0b601bee1e5e3c451ce964c7444`. `Credential.swift`
is the original struct, and `UnlockInterval.swift` is the old SwiftData entity
without the UI. The entity is deliberately compiled in module `Quiet`, matching
the persistent model identity. `GrantDraft.swift` supplies the old civil-time
helper. `provenance.json` pins every frozen file by SHA-256.

`prepare-build6-fixture.py` verifies these files, copies the isolated package
under ignored `.build/`, and runs `build6-generator.swift`. It creates synthetic
SQLite journals, a credential and a SwiftData disk store with **no remote
attribution fields**. Native migration tests open/reopen them using the current
app and check selections, six limits, exhaustion, pending setup, leases,
credentials, history identifiers, retention and new attribution. No phone data,
private Git objects, network fetch or full Git history is needed. A shallow
anonymous clone contains everything. Generation needs macOS 14+ and SwiftData.
Keep frozen schemas unchanged when evolving the current app.
