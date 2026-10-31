# Setup and tools

[Deutsch](de/setup.md)

Android Analyxer contains no third-party code. It calls external tools: the Android SDK for emulators and APK metadata, a JDK, and for code and runtime analysis REA with Node.js, JADX headless MCP and Frida. **Setup → Analysis Tools** checks all of them and installs what is missing on request.

## Checking

Each tool is shown as ready, outdated, missing or incomplete, with its version and path. The check looks in this order:

| Tool | Looks in | Ready when |
|---|---|---|
| JDK | tools folder `jdk/`, the tool profile, `/usr/libexec/java_home` | `bin/java` and `bin/javac` exist and the version is 17 or newer |
| Node.js | tools folder `node/`, the tool profile, `/opt/homebrew/bin/node`, `/usr/local/bin/node` | the version satisfies REA's `engines.node` (REA 6.8: `^22.23.4 \|\| ^24.22.1 \|\| >=26.12.1`) |
| REA | tools folder `rea/node_modules/rea-agents`, the tool profile | version 6.5.0 or newer and Frida's native component (`frida_binding.node`) is present |
| JADX headless MCP | tools folder `jadx/`, the tool profile | its SHA-256 matches the release that the installed REA specifies in `dist/android/JadxRelease.js` |
| Frida Java bridge | tools folder `frida-bridge/java-bridge.bundle.js`, the tool profile | the file exists |
| frida-server | tools folder `frida-server/` | a binary for the emulator architecture (arm64 on Apple Silicon) with exactly the Frida version that REA uses |
| Android SDK | the chosen SDK folder | `adb`, `emulator`, `aapt2`, `apkanalyzer`, `avdmanager` and `sdkmanager` are all present |

**Check Again** repeats the check. After each check the app points its tool profile at the tools that are ready, so code analysis uses them without further steps.

## Installing

Choose a tools folder first. The suggestion is `analyxer-tools` next to the SDK folder; any folder works, for example on an external disk. **Install …** (or **Update …**, **Repair …**) shows the source and size and starts only after you confirm. **Install Everything Missing …** installs all missing tools except the Android SDK, in the right order.

| Tool | Source | Verification | Size |
|---|---|---|---|
| JDK 25 | Eclipse Temurin via the [Adoptium API](https://api.adoptium.net) | SHA-256 from the API | about 130 MB |
| Node.js 24.22.2 | [nodejs.org](https://nodejs.org/dist/) | `SHASUMS256.txt` | about 50 MB |
| REA 6.8.0 | npm (`rea-agents`); Frida's native component is then fetched by Frida's own install script | npm integrity checks | about 220 MB plus 36 MB |
| JADX headless MCP | the GitHub release REA references | SHA-256 from REA | about 42 MB |
| frida-java-bridge 7.0.13 | npm, built locally with REA's Frida compiler | npm integrity checks | about 1 MB |
| frida-server | [Frida's GitHub releases](https://github.com/frida/frida/releases), matching REA's Frida version | SHA-256 digest from the GitHub API | about 17 MB |
| Android SDK | Google's command-line tools from `repository2-3.xml`, then `sdkmanager` | SHA-1 from Google's repository, then `sdkmanager` | about 150 MB plus the packages |

Every download uses HTTPS. A download whose checksum does not match is deleted and nothing is unpacked. Archives are extracted into a staging folder and only then moved into place, so a failed update leaves the previous version intact. npm runs with `--ignore-scripts` and its own cache inside the tools folder; the one install script REA needs (Frida's native component) is run explicitly afterwards.

### Android SDK

**Set Up …** (or **Add Packages …** when the SDK is already complete) opens a sheet that names the target folder and the packages: `platform-tools`, `emulator`, `build-tools;36.1.0`, `platforms;android-36` and, optionally, a Google Play system image (`system-images;android-36.1;google_apis_playstore;arm64-v8a` on Apple Silicon, about 2 GB). **Show Licences** loads Google's licence texts; this needs a JDK and downloads the command-line tools if they are missing, but accepts nothing. **Accept Licences and Install** accepts them and installs the packages.

### frida-server

The tool manager downloads frida-server to the tools folder. It does not copy it to a device: process observation needs a prepared analysis device on which frida-server runs; see [Code and data flow analysis](deep-analysis.md).

## Tool profile

The app keeps the paths it uses in a tool profile. Setup fills it automatically. For the command line, or to use tools from other places, a profile can also be a small JSON file; **Load Tool Profile …** in a project's code analysis section reads one:

```json
{
  "executable": "/absolute/path/node",
  "cliScript": "/absolute/path/rea-agents/scripts/rea.mjs",
  "jadxJAR": "/absolute/path/jadx-headless-mcp-0.7.1-all.jar",
  "javaHome": "/absolute/path/jdk/Contents/Home",
  "javaBridge": "/absolute/path/java-bridge.bundle.js"
}
```

The profile holds program paths only, no credentials. A standalone REA executable can be used without `cliScript`; empty optional paths are stored as empty strings.

## Command line

The same tool manager is available in the CLI:

```sh
swift run --disable-sandbox android-analyxer-cli setup check --tools /Volumes/Data/analyxer-tools
swift run --disable-sandbox android-analyxer-cli setup install frida-server --tools /Volumes/Data/analyxer-tools --profile tools.json
swift run --disable-sandbox android-analyxer-cli setup licenses --sdk /Volumes/Data/android-sdk
swift run --disable-sandbox android-analyxer-cli setup install android-sdk --sdk /Volumes/Data/android-sdk --accept-android-licenses
```

Tools: `jdk`, `node`, `rea`, `jadx`, `frida-bridge`, `frida-server`, `android-sdk` or `all`. `--profile` reads an existing tool profile so that tools outside the tools folder count. `--play-image` adds the Google Play system image. `install android-sdk` refuses to run until the licences are accepted, either earlier or with `--accept-android-licenses` after reading them with `setup licenses`.

## Licences

Each tool comes under its own licence; see [third-party notices](../THIRD_PARTY_NOTICES.md). The Android SDK licence must be accepted by you.
