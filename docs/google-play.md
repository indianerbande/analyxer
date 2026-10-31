# Google Play devices

[Deutsch](de/google-play.md)

## Using a Play device

1. Open Analyxer, choose **Devices**, and under **Create Google Play Device** create a device from an installed official Google Play system image (tablet or phone).
2. Leave **Keep changes permanently** on and start the device. Android opens in its own emulator window.
3. Once Android has started, choose **Open Google Play**. Sign in with your own Google account in the Android window and install apps from the store. Google may update its system apps first.
4. **Installed Apps → Load Apps**. Filter by package name and choose **Investigate …**. Save a new `.androidlab` folder.
5. The import keeps the base APK and all currently installed split APKs, analyses the base manifest and verifies the existing installation. **Launch Project App**, use the app, save screenshots and logcat, or hand an APK to REA under **Examine Code and Data Flows**.
6. After a restart or when you reopen a project, start a new test session and choose **Adopt Installed App**. After an app update, import again if the hashes no longer match.

The running store app is not replaced during the import. Accounts and app data live in the persistent AVD, not in the analysis project. Temporary mode discards changes when the emulator quits. Both modes start with `-no-snapshot -no-metrics`; persistent user data does not need snapshots.

## Managing devices

**Create Google Play Device** uses only locally installed, non-preview phone system images with `google_apis_playstore` and the host architecture. A new device can be a tablet (Pixel Tablet profile, 1920×1200 at 240 dpi, landscape) or a phone (Pixel 6); the form factor defaults to tablet. New AVDs are created in the folder chosen under **Setup → My Devices** (by default `avd` next to the SDK folder). Existing names are refused; there is no `--force` and no reset of existing devices.

**Devices** lists your own devices and Android Studio devices (the standard catalogue, e.g. `~/.android/avd`) in separate sections. Each card shows the system, read from `target` in `<Name>.ini` and the variant and architecture from `config.ini`. If both catalogues point to the same folder, each device appears once.

- **Rename** works only for your own, stopped devices. It updates `<Name>.avd`, `<Name>.ini` and its path, `AvdId` and `avd.ini.displayname` in `config.ini`, and `hardware-qemu.ini`. The new name must not exist in either catalogue. If anything fails, the previous state is restored. Apps, sign-in and data are kept.
- **Delete** works only for your own, stopped devices and asks first. The `.avd` folder and the `.ini` go to the Trash, provided the `.ini` points to exactly that folder.
- **Android Studio devices** can be started and controlled, but only deleted in Android Studio.

The app does not bundle SDK, JDK or system images. Install a missing Play image with **Setup → Analysis Tools → Android SDK** (optional Play image) or the Android Studio SDK Manager.

### Keyboard

New devices enable the Mac keyboard (`hw.keyboard=yes`, `hw.keyboard.lid=no`). **Enable On-Screen Keyboard** turns on Android's normal on-screen keyboard alongside the hardware keyboard and disables automatic stylus handwriting (`show_ime_with_hard_keyboard=1`, `stylus_handwriting_enabled=0`, documented in the [Android 16 source](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r2/core/java/android/provider/Settings.java)). A handwriting mode that is already open may need to be left through its menu or by restarting the device. The button checks both values it writes and changes no keyboard app data.

### Tablet layout

Tablets use 1920×1200 pixels at 240 dpi in landscape. Android then reports `sw800dp`, `w1280dp`, `h800dp`, `xlarge`, `land`. Only the AVD's display and skin settings differ from a phone.

## What is verified

Verified with the official Play image API 36.1 (ARM64): starting the store up to the visible sign-in, installing the project's own test app, a cold restart from the app and both installed test APKs surviving it. CLI and GUI import the base APK and a signed resource split; hash matching, launching without reinstalling and the full export work. Automated tests cover aborts on update or restart, a wrong split package name, tampering and the schema 3 round trip.

**Not yet verified:** signing in with a user account, an actual store download, account persistence and store updates. These steps need the user to sign in. APK set import has been verified with the project's own signed test app, not with a third-party app downloaded from a signed-in store.

## Limits

Official Google Play images do not allow `adb root` ([Android documentation](https://developer.android.com/studio/run/managing-avds)). Code analysis with REA, APK import, screenshots and accessible app logs work without root. Frida process observation needs a prepared analysis device. For that, the app offers to install the complete imported APK set there; a matching ABI and API level, dependencies and the app's ability to run on that device are your responsibility.

An installed APK set contains only the components installed for that device. On-demand features, additional files, private app data and other architectures of an app bundle are not included. The overview describes the base APK; REA analyses the APK you pick. Network capture is limited to the documented recording paths.

References: [Create and manage virtual devices](https://developer.android.com/studio/run/managing-avds) for Play Store profiles, system images and root limits; [Start the emulator from the command line](https://developer.android.com/studio/run/emulator-commandline) for startup and user data.
