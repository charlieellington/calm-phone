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
