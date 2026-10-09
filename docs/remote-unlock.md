# Remote unlock: development and verification

The same app supports a restricted phone, a helper phone, or both. A helper
opens a connection link without enrolling restrictions. Connection/removal
is PIN-free; changing policy or PIN remains authorized by the existing PIN.

## Records and grant path

`RemoteUnlock.swift` defines bounded parsing, record validation and verification.
`RemoteStores.swift` persists independent remote/connection records in the app’s
Keychain (`WhenUnlockedThisDeviceOnly`); extensions never read them. Retain
these service/account identities for in-place upgrades. Independent builders
can rename both remote and PIN services before their first installation.

A missing Keychain item allows first use. Read failures, corrupt/unsupported
records and failed writes cannot authorize or replace cached credentials.
Every mutation/issue reads authoritative storage. Verifiers serialize calls and
persist the spent nonce before producing a grant capability.

Pairing uses `c2.<phoneID>.<generation>.<remoteID>.<key>.<ownerName>`: opaque
16-byte phone and credential IDs, a rotating 32-byte key and base64url fields.
Generations increase across removal. Helpers replace only the same phone with
a newer generation; same names are distinct phones. Disconnect remembers the
latest generation. c1 links are refused; valid v1 issuer records migrate without
losing keys/spent nonces. Legacy helper rows remain usable/removable but cannot
be merged by display name; disconnect them when pairing with c2.

Unlock format remains u1, carrying duration, issue time, nonce and HMAC-SHA256
signature. The receiving phone allows age through 600 seconds and at most 120
seconds of sender clock lead. Its persisted freshness floor never decreases,
including after remove/re-add. It prunes nonces older than 720 seconds relative
to that floor and refuses new authorization at 4,096 live entries. A large
forward clock jump can leave subsequent links expired until time catches up;
PIN access remains independent. There are at most 256 remembered phone IDs.

`QuietModel.openLease` feeds both PIN and link capabilities through the grant
coordinator. Receiver-side time computes midnight with the existing minimum
interval. Verification spends the link even if grant scheduling subsequently
fails. `Lease.activatedAt`, optional `remoteID` and the historical `remoteName`
are the success evidence. Secondary Last unlock metadata retries from the
32-day journal; a failed metadata write cannot deny an already-active lease.
Removal retains historical names and does not end active access. Lock now does.

Success resets the root navigation stack and dismisses guardian/connection
surfaces to show the active timer. A refused URL alerts on the visible surface
and preserves unfinished setup. Inactive prompts retain pending URLs but
invalidate PIN authorization; a real background transition drops pending links.

## Links and independent builds

Generated HTTPS links use `https://www.ellington.design/calm/c#<token>` and
`/calm/u#<token>`. The app accepts only those routes on the exact host, plus
`quiet://connect?t=<encoded-token>` and `quiet://unlock?t=<encoded-token>`.
Keep the `quiet` scheme on both phones. The existing static pages read the
fragment locally and put its encoded value on an **Open in Calm Phone** button.
The fragment is excluded from HTTP requests. Connection links contain a private
key and unlock links contain a signed capability; neither belongs in logs,
analytics, transcripts or public screenshots.

The domain’s Apple association lists one configured team and bundle ID. Using
your own team/bundle IDs does not add your identity to it: open the link in a
browser and use the button. Some messaging in-app browsers require **Open in
browser** first. Browser/parser contracts are automated; physical Universal
Links, messaging delivery, prompts and signed persistence need testing with
your identity on your phones. The main app alone has Associated Domains;
extensions do not. The developer-mode entitlement is for explicit development
testing, not proof of normal Universal Links delivery.

For an optional builder-controlled domain:

1. Change `RemoteLink.host` and the main app’s associated-domain entitlement
   together. Keep the exact `/calm/c` and `/calm/u` paths and fragment-only tokens.
2. Serve matching static fallback pages with `no-referrer`, no analytics/external
   scripts and bounded fragments; their button uses the same encoded custom URL.
3. Serve `/.well-known/apple-app-site-association` as HTTPS JSON without redirects,
   listing your signed `<TeamID>.<mainBundleID>` and those two paths/fragments.
   Update only your own domain; this repository update changes no live association.
4. Create signing profiles with the associated-domain capability. Check origin
   and Apple CDN association, then test normal links with development override off.

No account, push notification or server-side unlock verification is involved.
Static fallback pages and your messaging app still use the network for delivery.

## Reproduce public checks

```sh
git clone --depth 1 https://github.com/charlieellington/calm-phone.git
cd calm-phone
make check
make test-ios
QUIET_SIMULATOR_ID=<small-iPhone-simulator> make test-ui
```

Use a Mac with Xcode, Python 3 and an installed iPhone runtime. `make check`
includes strict Swift formatting, core/PIN/remote tests, five Shortcut tests,
process concurrency/death/replay checks, source/identity audits and unsigned
Debug plus Release builds of all five products. `make test-ios` generates the
self-contained old-format synthetic disk stores before running native, migration
and actual UI tests; `make test-ui` repeats UI/accessibility on a smaller phone.
No signing account, phone, private dependency or full Git history is needed.

The public Actions workflow clones the proposed public SHA **anonymously with
`--depth 1`**, checks it against the requested SHA, records source hashes,
executes `make check`, both native lanes and fresh product inspection. The URL
bridge confirms cold/warm navigation on synthetic fixtures; it tests custom
URLs, not physical Universal Link delivery. Machine-readable receipts, xcresults,
synthetic screenshots, fixture provenance and an unsigned archive are retained
under the workflow artifact. Logs/results stay in ignored `.build/` locally.

Only `testKeychainRecordsRoundTripAndLeaveTheSimulatorClean` may skip for a
diagnosed isolated Security write `-34018` (`errSecMissingEntitlement`) in an
unsigned test host. Unexpected Security errors, other skips and missing native
tests fail verification. Injected storage-failure tests still run. Unsigned
builds and fixtures cannot prove signed Keychain persistence, actual shielding,
expiry during idle/reboot, WhatsApp delivery or installation/profile correctness.

Charlie’s reported successful use on both phones on 8 October 2026 is separate
from these reproducible public checks. It does not fill every earlier physical
acceptance row, and its installed SHA is not established.
