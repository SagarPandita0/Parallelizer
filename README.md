# Parallelizer

Parallelizer lets you run multiple independent copies of the same macOS app.

It works by cloning an app bundle, giving the clone a new bundle identifier, re-signing it, and launching it as a separate app. That makes macOS treat each clone as its own application instead of collapsing everything into a single running instance.

## What It Does

- Clones a selected `.app` into `~/Applications/Parallelizer/`
- Assigns the clone a unique `CFBundleIdentifier`
- Updates Electron helper bundle identifiers when needed
- Re-signs the cloned bundle with an ad-hoc signature
- Launches the clone as a separate app instance
- Creates a per-profile folder under `~/Library/ParallelizerProfiles/`

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
- Keychain-backed credentials
- Sandboxed or App Store apps
- Apps that expect a custom profile directory flag

In short: separate app bundle does not always mean separate app data.

## Requirements

- macOS
- Xcode, if you want to build from source

Parallelizer uses `/usr/bin/codesign` for ad-hoc signing.

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