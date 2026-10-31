# Fremdwerkzeuge

Android Analyxer selbst steht unter der [MIT-Lizenz](LICENSE) und hat keine Swift-Abhängigkeiten von Drittanbietern. Zur Laufzeit ruft er jedoch externe Werkzeuge auf. **Keines davon ist in diesem Repository oder in der gebauten App enthalten**; sie werden vom Nutzer selbst installiert und gelten unter ihren eigenen Lizenzen.

| Werkzeug | Wofür | Quelle | Lizenz |
|---|---|---|---|
| Android SDK: Emulator, Platform-Tools (`adb`), Build-Tools (`aapt2`), Command-line Tools (`apkanalyzer`, `avdmanager`, `sdkmanager`) | Emulatoren, Gerätezugriff, APK-Analyse | [developer.android.com](https://developer.android.com/studio) | Android Software Development Kit License Agreement (Google); muss vom Nutzer angenommen werden |
| Android-Systemimages, auch mit Google Play | Laufzeit der Emulatoren | über `sdkmanager` | Google-Lizenzbedingungen; Google-Play-Images mit zusätzlichen Bedingungen |
| Java Development Kit (z. B. Eclipse Temurin, Azul Zulu) | `avdmanager`, `apkanalyzer`, JADX | [adoptium.net](https://adoptium.net), [azul.com](https://www.azul.com/downloads/) | GPLv2 mit Classpath Exception |
| Node.js | Laufzeit für REA und den Frida-Bridge-Bau | [nodejs.org](https://nodejs.org) | MIT |
| REA (`rea-agents`) | Codeanalyse und Prozessbeobachtung | [npm](https://www.npmjs.com/package/rea-agents), [github.com/morluto/rea](https://github.com/morluto/rea) | MIT |
| JADX headless MCP (`jadx-headless-mcp-*-all.jar`) | Java-/Kotlin-Dekompilierung für REA | GitHub-Release des Projekts | eigene Lizenz vor Weitergabe prüfen; enthält u. a. JADX (Apache-2.0) und smali/baksmali (BSD) |
| Frida: `frida-server`, `frida-java-bridge`, `frida-compile` | Beobachtung von Java-Methoden im App-Prozess | [frida.re](https://frida.re), npm | LGPL-2.0 mit wxWindows-Ausnahme 3.1 |

Wer einen gebauten Analyxer zusammen mit einem dieser Werkzeuge weitergibt, muss dessen Lizenzbedingungen selbst einhalten. Der Analyxer lädt Werkzeuge nicht heimlich nach; was er aufruft, steht in der Einrichtung bzw. im Werkzeugprofil.
