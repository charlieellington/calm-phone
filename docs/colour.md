# Optional evening greyscale

Calm Phone decides from the phone's local time: colour from 09:00 to 19:00,
greyscale at other times. The app's UIKit API can only read the filter
state. A native **Set Colour Filters** action in Shortcuts changes it.
Display colour does not grant or remove app access.

## Generate and import

Build your app with your own signing configuration first. In Xcode's
Products group, use **Show in Finder** on the built `Quiet.app` to find its
path. On the Mac, from this repository:

```sh
python3 scripts/colour_shortcuts.py \
  --signed-app /path/to/Quiet.app \
  --output .build/colour-shortcuts --sign
make test-shortcuts
```

The generator reads your app's bundle identifier and signing metadata; it
does not sign the app or touch phone data. Apple's `shortcuts sign` produces
importable workflows. Local generated files contain your signing metadata
and remain ignored. Import the generated `.shortcut` files on your Mac and
let Shortcuts sync them to your iPhone, or transfer them directly to it.

Three workflows are produced:

- **Calm Phone Colour**: read the app's `on`/`off` decision, enable or disable
  Colour Filters, then record a check in the app.
- **Calm Phone Set Grayscale**: enable Colour Filters.
- **Calm Phone Set Colour**: disable Colour Filters.

## Set up on the iPhone

1. In **Settings → Accessibility → Display & Text Size → Colour Filters**,
   select **Grayscale**. Keep a manual Accessibility Shortcut available.
2. During PIN-authorised access, open Shortcuts and run **Calm Phone Colour**
   interactively once. Approve its first-run permission prompts.
3. In **Shortcuts → Automation**, add a daily **Time of Day** automation at
   **09:00** that runs **Calm Phone Colour**. Select **Run Immediately** and
   turn **Notify When Run** off. Repeat at **19:00**. Personal automations
   are created on the phone; importing a shortcut does not create them.
4. Create a temporary Time of Day trigger a few minutes ahead. With Calm
   Phone closed and restrictions active, observe the expected screen colour
   and a fresh **Last checked** timestamp. Test with the hardware screen
   locked as well. Remove the temporary trigger afterwards.

The generator includes an iOS 26 correction for its text comparison and
variable input. This generated input format needs one real import and run
on your phone; the working reference workflow was corrected in the phone
editor. If import leaves an empty condition, edit it to **If Colour setting
is on**. Its first branch must turn filters On, Otherwise Off, followed by
the app's check action. Observe the actual screen before accepting setup.

## Current limits

Daily runs ignore timed app access. Automatic colour change at an arbitrary
unlock expiry, colour-only expiry or **Lock now** is not implemented.
Two daily automations do not provide that behaviour. App restrictions and
their timers remain independent. No additional app whitelist exception is
needed merely to set colour.

**Last checked** records a timestamp, but its matched/not-matched message
can report a stale Grayscale observation immediately after the setter.
Use the visible display as the check. A host test or imported workflow
cannot prove unattended execution while the hardware screen is locked;
the test above is required on your phone.
