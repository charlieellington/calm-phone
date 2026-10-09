# Source provenance

Calm Phone is built on [Foqos](https://github.com/awaseem/foqos) by Ali Waseem,
version **v2.3.2**, revision **4f6864ce9f821d0dcb873b253dfd786834a047a8**
(`4f6864ce`). The original MIT copyright and permission notice are preserved
in [LICENSE](LICENSE). Charlie Ellington's changes use the same licence.

This repository contains a fresh source snapshot of the app installed on
Charlie’s phone as Calm Phone 1.0 (6) on 6 October 2026. Its source revision
is `805fb556ab5828ab2d29ffa7b8bdfd27226933e1`. The colour Shortcut generator
includes the subsequent condition/input correction from
`55b183a451d2c2c2987cce6094fafd52cd2e19a0`.

Publication changes make PIN-holder copy generic, generate synthetic PINs
only inside tests, keep local build output ignored, and let the Shortcut
generator and identity audit follow the builder's own bundle identifiers.
The Screen Time policy, PIN storage, app-access timers and history behaviour
come from the installed snapshot. No private repository history, planning,
phone data, signing credentials or device evidence is included.


## Remote unlock — public update, 9 October 2026

Build 7 ports the completed c2 pairing/u1 signed-unlock implementation as
source files into this repository’s existing history. It includes app/setup
navigation, private Keychain storage, grant/history attribution and regression
tests. No private Git history or private evidence is imported. The publication
adaptations above remain: generic product copy, generated synthetic test PINs,
identifier-aware audits/Shortcut generation and ignored build output.

Upgrade testing freezes the public predecessor’s schema at
`2e04a43e287cd0b601bee1e5e3c451ce964c7444` in `scripts/fixtures/build6/` with a
hash manifest. Its isolated `Quiet` module writes synthetic SQLite and SwiftData
stores; shallow clones need no older Git objects. The new public images are
flattened, stripped of metadata and, for the messaging example, cropped and
opaquely redacted. Supplied app screenshots retain first names as an example.

Charlie reports successful installation and unlock-link use on his and Bene’s
phones on 8 October 2026. This is dated user-reported use with screenshots,
not a known installed SHA or a full historical acceptance verdict. Public
revision validation and unsigned/signed limitations are recorded separately
in the update PR and [developer docs](docs/remote-unlock.md).
