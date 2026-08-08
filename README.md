# Parallelizer

Parallelizer lets you run multiple independent copies of the same macOS app.

It works by cloning an app bundle, giving the clone a new bundle identifier, re-signing it, and launching it as a separate app. That makes macOS treat each clone as its own application instead of collapsing everything into a single running instance.

## What It Does

- Clones a selected `.app` into `~/Applications/Parallelizer/`
- Assigns the clone a unique `CFBundleIdentifier`
- Updates Electron helper bundle identifiers when needed
- Installs a launch shim inside the clone so the profile environment applies
  no matter how the clone is opened (Finder, Dock, Spotlight, or Parallelizer)
- Badges the clone's icon with the profile's first letter so clones are
  easy to tell apart in the Dock and Spotlight
- Re-signs the cloned bundle with a private "Parallelizer Signing"
  identity that is created automatically on first use (ad-hoc as a
  fallback), so keychain and permission approvals survive re-cloning
- Shows when a clone's original app has updated, with one-click Refresh
- Launches the clone as a separate app instance
- Creates a per-profile folder under `~/Library/ParallelizerProfiles/`
- Lists installed clones so you can launch, reveal, or delete them
- Preserves profile data when you re-clone with the same profile name, so
  refreshing a clone after an app update keeps its logins and settings

Example outputs:

- `Slack Work.app`
- `Chrome Personal.app`
- `Codex Test.app`

## Why It Exists

On macOS, apps with the same bundle identifier are generally treated as the same application. That makes it awkward to keep separate accounts, workspaces, or test environments open at the same time.

Parallelizer creates uniquely identified clones so macOS will run them side by side.

## What To Expect

Parallelizer is useful for apps that behave well when duplicated, but it does not guarantee full isolation.

Works well for:
- Running multiple visible app instances
- Keeping separate Dock icons
- Creating distinct cloned app bundles for different profiles

May still require app-specific handling for:
- Shared login sessions
- Apps that use the iCloud (data-protection) keychain
- Sandboxed or App Store apps
- Apps that expect a custom profile directory flag

In short: separate app bundle does not always mean separate app data.

## Requirements

- macOS
- Xcode, if you want to build from source

Parallelizer uses `/usr/bin/codesign` for ad-hoc signing.

## Build and Install (personal use, no Apple developer account)

Parallelizer builds with Xcode's "Sign to Run Locally" ad-hoc identity, so no
paid Apple Developer membership is needed. The build runs on the Mac that
built it; on another Mac, Gatekeeper requires right-click → Open once, or a
rebuild on that machine.

```bash
./scripts/build-install.sh
```

This produces a Release build and installs it to `/Applications/Parallelizer.app`.

## Browser Extension Integration

Apps that pair with a browser extension through native messaging (for
example ChatGPT in Chrome) register a host manifest under HOME — which for
clones lands in the profile home, where real browsers never look. On every
launch, the clone's shim publishes those manifests into your real home for
each installed browser (Chrome and its variants, Chromium, Edge, Brave,
Vivaldi, Firefox), rewriting each one to start the host through a wrapper
that restores the clone's profile environment.

Notes:

- A browser extension can only talk to one instance per host name, so the
  most recently launched registrant wins — the original app or a clone.
- Registrations an app makes mid-session are published the next time the
  clone launches.

## Keychain

Each clone gets its own keychain (`parallelizer.keychain-db` inside the
profile home), created automatically on first launch so apps can store
logins and tokens without hitting "A keychain cannot be found." Your real
login keychain is never touched, and clone credentials never land in it.

The profile keychain is a plain default keychain with an empty password,
kept unlocked. It is deliberately not registered as the "login" keychain:
macOS keeps the login keychain's password in sync with your account
password, which would override the empty password and trigger repeated
credential prompts. Because clones are signed with a stable identity and
own the items they create, access is silent after the first launch.

That empty password is convenient for personal use but weaker protection
than your login keychain, so avoid storing high-value credentials in
clones. Deleting a clone's profile data deletes its keychain with it.

## Updating Clones

In-app auto-updaters cannot work inside a clone: the update is signed by
the original developer, the clone is re-signed by Parallelizer, and the
updater correctly refuses the mismatch ("improperly signed" errors are
expected — cancel them). Instead, let the original app update itself,
then click Refresh on the clone in Parallelizer. The clone list shows
"Update available" when the original's version is newer, and Refresh
re-clones from the original while keeping all profile data, logins, and
settings.

## Signing

Clones are signed with a private self-signed certificate ("Parallelizer
Signing") kept in its own empty-password keychain at
`~/Library/Application Support/Parallelizer/signing.keychain-db`. It is
created automatically the first time a clone is signed. Because the
identity is stable, macOS keeps treating a refreshed clone as the same
app: keychain approvals and privacy permissions persist across refreshes
and app updates. The certificate never leaves your machine.

## Deleting Clones

Delete clones from within Parallelizer. Deleting moves the clone to the
Trash, with a choice to keep or also trash the clone's profile data
(its logins and settings).

## Usage

1. Open Parallelizer.
2. Click **Select App** and choose a `.app`.
3. Enter a profile name such as `Work`, `Personal`, or `Test`.
4. Click **Create Parallel App**.

Output locations:

- Cloned apps: `~/Applications/Parallelizer/`
- Profile folders: `~/Library/ParallelizerProfiles/<app>/<profile>/`

If you recreate an existing profile, Parallelizer resets that profile’s folder before launching the new clone.

## How It Works

1. Copy the selected app bundle into `~/Applications/Parallelizer/`
2. Rewrite the cloned app’s `Info.plist` with a unique bundle identifier
3. If the app is Electron-based, update helper app bundle identifiers inside `Contents/Frameworks/*.app`
4. Re-sign the cloned bundle with an ad-hoc signature
5. Launch the cloned app

## Limitations

Some apps will not clone cleanly.

Problem cases usually include:
- App Store apps
- Sandboxed apps
- Apps with strict signature or integrity checks
- Apps that self-update aggressively
- Apps that store important state outside their app bundle or profile directory

Parallelizer does not attempt deep app-specific isolation on its own.

## Safety

Parallelizer modifies cloned app bundles, not the original app you select.

You should still use it carefully:
- Only clone apps you trust
- Only modify software you have the right to use and copy
- Expect some apps to break, refuse to launch, or share state unexpectedly

## Build From Source

Open `Parallelizer.xcodeproj` in Xcode, select the `Parallelizer` scheme, and run.

Optional CLI build:

```sh
xcodebuild -project Parallelizer.xcodeproj -scheme Parallelizer -sdk macosx build
```
