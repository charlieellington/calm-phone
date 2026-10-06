# Calm Phone — Your iPhone, without the scroll.

Every app locked except the useful ones. Someone you trust holds the PIN.
Unlock for 15 minutes, an hour or until midnight. Then it locks itself again.

Built on [Foqos](https://github.com/awaseem/foqos) and Apple's Screen Time
controls. Free code, [MIT licence](LICENSE). You build it yourself in Xcode.

## How it works

1. **Locked** — everything is shielded except your allowed apps and the
   remaining allowance for limited apps.
2. **The PIN** — someone you trust types it; you never see it.
3. **Timed** — 15 minutes, an hour or until midnight, then it locks again
   on its own. Temporary access applies to all apps.

**History** shows unlocks and time unlocked per day. It measures authorised
access time, rather than time spent using apps, and keeps a 30-day view.

## Keep, limit, block

The starting arrangement described on the [tool page](https://www.ellington.design/tools/calm-phone):

| Keep | Limit | Block |
| --- | --- | --- |
| Calls, messages, WhatsApp, camera, maps, music, the bank. | Photos, Maps, Weather, Files: ten minutes a day. Claude: thirty. | Browsers, mail, Instagram, LinkedIn, X, YouTube, the App Store, and everything not on your list. |

You choose your own apps during setup. Nothing is preselected: Apple gives
the app private selection tokens, so it cannot choose apps by name. There
are six default limit slots: Photos, Apple Maps, Google Maps, Weather and
Files at 10 minutes each, and Claude at 30. Maps are useful tools with a daily
allowance in this arrangement. Each slot must have a different selected
app. All other selected apps are kept; unselected apps are blocked.

Pick up to 50 apps in total. After setup, **Settings → Apps and limits →
Edit apps and limits** lets the PIN holder change selections, slot
assignments and minutes. A coding agent can change the default slots too.

## What you'll need

- **A Mac with Xcode.** The installed source was built with Xcode 26.6 and
  iOS 26.5 SDK. This public snapshot is checked with Xcode 26.3 and iOS 26.2
  SDK. The project minimum is **iOS 18.5**, iPhone only.
- **An Apple Developer account:** €99 a year, listed in your local currency
  at sign-up. Family Controls and App Groups must be available to your team.
- **Your iPhone:** nothing wiped, nothing deleted.
- **Someone you trust** to set and hold the six-digit PIN.

No App Store, no TestFlight: you build it onto your own phone over a cable.

## Install

1. Clone and open the project on your Mac:

   ```sh
   git clone https://github.com/charlieellington/calm-phone.git
   cd calm-phone
   open Quiet.xcodeproj
   ```

   Select the shared **Quiet** scheme. The internal project name is retained.

2. In **Signing & Capabilities**, select your own development team for all
   five targets: `Quiet`, `QuietMonitor`, `QuietShieldConfig`,
   `QuietShieldAction`, and `QuietWidget`. Change their bundle identifiers
   from `design.ellington.quiet*` to your own unique identifiers, keeping
   each extension's identifier prefixed by the app's identifier. Change test identifiers too
   if you will run the native tests. You can keep your development team
   setting locally in ignored `Config/Signing.local.xcconfig`.

3. Register your own shared **App Group**. Replace
   `group.design.ellington.quiet` in all five `.entitlements` files and
   `QuietShared/SharedContainer.swift`, and select that group on each
   target. Update the URL type identifier in `Quiet/Info.plist` and the
   Keychain service in `Quiet/PINStore.swift` to your own bundle prefix.
   Keep the internal `quiet` URL scheme. Configure Family Controls for the
   app, monitor and both shield targets; the entitlements are already in
   the project. Xcode must create profiles covering these capabilities.

4. Connect the iPhone over a cable, trust the Mac, and enable Developer Mode
   when iOS requests it. Choose the phone as Xcode's destination and run
   the **Quiet** scheme. Resolve any signing/capability errors in Xcode.

5. Open **Calm Phone**. Approve Screen Time access. In **Selected apps**,
   choose individual Keep and Limit apps, rather than whole categories or
   websites. In **Daily limits**, match each of the six slots to its actual
   app in the selection. Review the allowed apps and limits.

6. Hand the phone to the PIN holder. They tick the review confirmation,
   privately enter and confirm a six-digit PIN, and tap **Activate
   restrictions**. This app PIN is separate from iOS's Screen Time code.
   App installation and removal stay restricted even during an unlock.

7. Arrange useful apps and Calm Phone on the Home Screen using normal app
   icons. Optional wallpapers are [paper](docs/wallpapers/calm-phone-paper.png)
   and [evening](docs/wallpapers/calm-phone-evening.png); save one to Photos
   and choose it in iOS Wallpaper settings. The widget extension remains
   for compatibility, but its date and launcher widgets are retired and
   show **Widget removed**. Remove an old widget and use normal icons.

To unlock, tap **Unlock**, hand over the phone for the PIN, choose **15
minutes**, **1 hour** or **Until midnight**, check the displayed end time,
and tap **Unlock** again. Midnight uses the phone's local time; that option
is unavailable within 15 minutes of midnight. Tap **Lock now** to end access
early without a PIN. Open **Settings → History** to read each day's unlock
count and time unlocked. Daily limits and History use Europe/Brussels days
in this snapshot; see `CivilTime.calendar` to change that in code.

The public clone, project loading and unsigned compilation can be checked
without phone access. Team/profile setup, installation, Screen Time approval
and on-phone behaviour require your own Mac, account and iPhone. After
setup, check one allowed app, one blocked app, a full timed unlock with Calm
Phone closed, early locking and a daily limit on your phone. iOS can delay
Device Activity callbacks while the device is idle; verify restoration on
waking before relying on the timer.

## Optional: evening greyscale

The **Calm Phone Colour** Shortcut is generated by
[`scripts/colour_shortcuts.py`](scripts/colour_shortcuts.py). Run it from
two daily **Time of Day** automations, at **09:00** and **19:00**, using
**Run Immediately**. The app decides whether filters should be on; the
Shortcut sets Apple's Colour Filters. Select **Grayscale** in iOS settings
first.

Follow [docs/colour.md](docs/colour.md) to generate and import it for your
signed app. Run it interactively once to approve permissions, then perform
one real automation test on the phone. The generated condition/input fix
still needs that import test. The daily schedule works independently of
app unlocks. Automatic colour return after a timed unlock or early lock is
not implemented. The app's **Last checked** matching message can be stale;
check the visible display.

## Change it with a coding agent

Ask an agent to change your apps, limits or home rows. Start it with
[`AGENTS.md`](AGENTS.md), then use `make help`, `make test`,
`make test-shortcuts`, `make test-integration`, `make build`, `make build-ios`
and `make check`. Home rows are ordinary iOS icons; `Policy.quotas` holds
the default limits. There are no remote package dependencies or private
tools. Native build output and logs stay in ignored `.build/`.

## Honest limits

It's friction, not security. A full wipe from a Mac gets round it. Links
inside allowed apps still open. Screen Time authorisation can be revoked
by the phone's owner. The PIN holder is a person, not a security product.

## Privacy

Nothing leaves the phone. No account, no analytics, no network calls.
Selections, limits, PIN credentials and History stay on the phone. Optional
Shortcuts import/sync uses Apple's own Shortcuts service.

## The story

[The story](https://www.ellington.design/emails/calm-phone) ·
[The tool page](https://www.ellington.design/tools/calm-phone)

## Credits

[Foqos](https://github.com/awaseem/foqos) by Ali Waseem, MIT. Charlie's changes
under the same licence. See [UPSTREAM.md](UPSTREAM.md) for the pinned source
and public snapshot provenance.

## Support

Shared as a working tool, no support promised. On Charlie's phone since
4 October 2026.
