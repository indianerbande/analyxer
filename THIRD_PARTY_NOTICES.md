# Third-party tools

Analyxer itself is licensed under the [MIT licence](LICENSE) and has no third-party Swift dependencies. At runtime it calls external tools. **None of them is part of this repository or of the built app.** You install them yourself, or the tool manager in Setup downloads them on your explicit request from their official sources; each comes under its own licence.

| Tool | Used for | Source | Licence |
|---|---|---|---|
| Android SDK: Emulator, Platform Tools (`adb`), Build Tools (`aapt2`), Command-line Tools (`apkanalyzer`, `avdmanager`, `sdkmanager`) | emulators, device access, APK analysis | [developer.android.com](https://developer.android.com/studio) | Android Software Development Kit License Agreement (Google); you must accept it yourself |
| Android system images, including Google Play images | the emulators' runtime | via `sdkmanager` | Google's licence terms; Google Play images carry additional terms |
| Java Development Kit (e.g. Eclipse Temurin, Azul Zulu) | `avdmanager`, `apkanalyzer`, JADX | [adoptium.net](https://adoptium.net), [azul.com](https://www.azul.com/downloads/) | GPLv2 with Classpath Exception |
| Node.js | runtime for REA and for building the Frida bridge | [nodejs.org](https://nodejs.org) | MIT |
| REA (`rea-agents`) | code analysis and process observation | [npm](https://www.npmjs.com/package/rea-agents), [github.com/morluto/rea](https://github.com/morluto/rea) | MIT |
| JADX headless MCP (`jadx-headless-mcp-*-all.jar`) | Java/Kotlin decompilation for REA | the project's GitHub release | check its licence before redistributing; it bundles JADX (Apache 2.0) and smali/baksmali (BSD), among others |
| Frida: `frida-server`, `frida-java-bridge`, `frida-compile`, the `frida` Node module | observing Java methods in the app process | [frida.re](https://frida.re), npm, GitHub releases | LGPL 2.0 with wxWindows Library Exception 3.1 |

If you distribute a built Analyxer together with any of these tools, you must comply with their licence terms yourself. The app never downloads tools silently: Setup names the source and size of each download and waits for your confirmation.

Android is a trademark of Google LLC.
