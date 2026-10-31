# Analyxer

[Deutsch](README.de.md)

A native macOS workspace for Android emulators, APK analysis and device care. Analyxer runs the emulator from the official Android SDK in its own window and adds what the SDK leaves to the command line: Google Play devices you keep, a plain-language profile of every app you examine, analysis projects that keep evidence together, code analysis with [REA](https://github.com/morluto/rea) and JADX, targeted runtime observation with Frida, and cleanup tools for the device itself.

The app is written in SwiftUI, has no third-party Swift dependencies and runs everything locally. It does not upload APKs anywhere.

Version 0.4 · macOS 14 or later · tested on Apple Silicon with ARM64 images of Android 14 to 16. Intel Macs are untested.

## Features

- **Devices.** Create Google Play tablets or phones from official system images, start them permanently (apps and sign-in survive) or temporarily, rename and delete your own devices. Devices from Android Studio appear in a separate section and can be started, but never deleted. Every card shows the system, e.g. "Android 16 · API 36.1 · Google Play · ARM64".
- **App profile.** Every analysis project opens with a profile in plain language: Android versions, size, technology (Unity with IL2CPP, Flutter, React Native …), architectures, origin, notable points at a glance, permissions grouped by topic with Android's protection level, detected libraries by purpose (advertising, analytics, crash reporting, payments …) and what other apps or links can start.
- **Analysis projects.** A project keeps one app version (a single APK or an installed base/split set) together with static findings and any number of documented test sessions: install, launch, screenshots, app logcat, notes. Everything is saved immediately with a SHA-256 hash and timestamp and can be exported and reopened.
- **Code and data flows.** Hand the unchanged project APK to REA/JADX to search classes, list methods, decompile and follow references. Observe arguments and return values of selected Java methods in the running app with REA/Frida. Record mobile/WAN traffic of an SDK emulator or import a PCAP.
- **Installed apps and device care.** List all apps of a device with storage, origin and last use; disable, remove for the user, restore or uninstall them after confirmation. See where storage goes, clear all app caches and remove leftover folders of uninstalled apps. Everything works over ADB, without root and without an app on the device.
- **Tool manager.** Setup checks every external tool, explains what is missing and installs it on request from the official source, verified against the published checksum.
- **English and German.** The interface follows the system language; Setup → Language overrides it.

## Getting started

### 1. Build

You need Xcode with Swift 6 or later.

```sh
scripts/build-app.sh
open '/Applications/Analyxer.app'
```

The script builds `dist/Analyxer.app`, signs it ad hoc and replaces `/Applications/Analyxer.app`. The app is not notarized; there are no binary releases yet.

### 2. Set up the tools

Open **Setup**. The app looks for the Android SDK in `ANDROID_HOME`, then `ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`; you can choose another folder. Under **Analysis Tools** it checks:

| Tool | Needed for |
|---|---|
| Java Development Kit (17 or newer, 25 is installed) | JADX and the Android command-line tools |
| Android SDK | emulator, `adb`, `aapt2`, `apkanalyzer`, `avdmanager`, `sdkmanager` |
| Node.js (a version REA supports) | REA and building the Frida bridge |
| REA | code analysis and process observation |
| JADX headless MCP | decompiling Java and Kotlin for REA |
| Frida Java bridge | observing Java methods in the app process |
| frida-server | runs on the analysis device; must match REA's Frida version |

Choose a **tools folder** first: the app suggests `analyxer-tools` next to the SDK, and any folder works, for example on an external disk. **Install …** names the source and approximate size before it downloads anything. Downloads come only from the official sources (Adoptium, nodejs.org, npm, GitHub releases, Google's SDK repository) and are verified against their published SHA-256 or SHA-1 before they are unpacked. The Android SDK shows Google's licences, which you accept yourself. Details: [Setup and tools](docs/setup.md).

Tools you already have are detected and used where they are.

### 3. First steps

1. **Devices → Create Google Play Device**, start it, choose **Open Google Play** and sign in inside the Android window.
2. Install an app from the store, then **Installed Apps → Load Apps → Investigate …** to copy it into a new analysis project. Or use **Open APK …** for an APK file.
3. Read the app profile, open **Details & Evidence** for the raw data, start a test session, and record what you observe.

Choose where your own devices live under **Setup → My Devices**. By default that is a folder `avd` next to the SDK.

## Documentation

- [Setup and tools](docs/setup.md): tool manager, sources, checksums, tool profile, command line
- [Analysis projects](docs/project-workflow.md): workflow, file format, integrity, static analysis
- [Google Play devices](docs/google-play.md): creating and managing devices, importing installed apps, limits
- [Code and data flow analysis](docs/deep-analysis.md): REA/JADX, Frida method observation, network capture

German versions are in [docs/de](docs/de).

## Responsible use

Analyxer is meant for apps you are allowed to examine: your own apps, apps you test on behalf of their owner, and research that respects the law and the terms that apply to you. Decompiling, observing or redistributing someone else's app may be restricted by copyright, licence terms or local law. Do not use the device care functions on devices you do not own or manage. You are responsible for what you analyse and what you do with the results.

Observation through Frida needs a prepared analysis device. The app does not root devices, does not install certificates and does not bypass certificate pinning.

## Development

```sh
CLANG_MODULE_CACHE_PATH="$TMPDIR/analyxer-clang-cache" swift test --disable-sandbox
swift run --disable-sandbox analyxer-cli diagnose
swift run --disable-sandbox analyxer-cli setup check
swift run --disable-sandbox analyxer-cli care emulator-5554
swift run --disable-sandbox analyxer-cli profile path/to/project.androidlab
```

`--disable-sandbox` concerns the Swift package manifest process, not macOS security. The test suite (86 tests) needs no Android device.

- `Sources/Analyxer`: SwiftUI app
- `Sources/AnalyxerCore`: SDK and process adapters, static analysis, app profile, projects, device care, tool manager
- `Sources/AnalyxerCLI`: diagnostics, setup and integration tests
- `Resources/Localization`: German translation (English is the source language)
- `fixture/`, `scripts/build-fixture.sh`: a synthetic test app built from source with the local SDK

End-to-end tests run only on an emulator you name explicitly and accept only the synthetic fixture package:

```sh
scripts/build-fixture.sh
swift run --disable-sandbox analyxer-cli smoke emulator-5580 \
  .local/fixture/analyxer-fixture.apk .local/smoke
```

`care SERIAL` prints storage, the largest apps and leftovers and changes nothing. `care-smoke EMULATOR-SERIAL` runs every care action once (it disables and restores YouTube, clears caches, creates and deletes an artificial leftover) and is meant only for a disposable emulator.

### Open work

Store sign-in and downloads with a user account are not yet tested end to end. Not implemented: cloning AVDs, an embedded Android view, keymapping and gamepads, snapshot management, native/JNI probes, complete Wi-Fi capture, notarized releases.

## Licence

MIT, see [LICENSE](LICENSE). The external tools (Android SDK, JDK, Node.js, REA, JADX, Frida) are not part of this repository or the app and come under their own licences; see [third-party notices](THIRD_PARTY_NOTICES.md).

Android is a trademark of Google LLC. Analyxer is an independent project and is not affiliated with or endorsed by Google.
