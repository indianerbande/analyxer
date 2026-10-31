# Einrichtung und Werkzeuge

[English](../setup.md)

Android Analyxer enthält keinen Code von Drittanbietern. Er ruft externe Werkzeuge auf: das Android SDK für Emulatoren und APK-Metadaten, ein JDK und für Code- und Laufzeitanalyse REA mit Node.js, JADX headless MCP und Frida. **Einrichtung → Analysewerkzeuge** prüft sie alle und installiert auf Wunsch, was fehlt.

## Prüfung

Jedes Werkzeug wird als bereit, veraltet, fehlend oder unvollständig angezeigt, mit Version und Pfad. Die Prüfung sucht in dieser Reihenfolge:

| Werkzeug | Sucht in | Bereit, wenn |
|---|---|---|
| JDK | Werkzeugordner `jdk/`, Werkzeugprofil, `/usr/libexec/java_home` | `bin/java` und `bin/javac` vorhanden sind und die Version 17 oder neuer ist |
| Node.js | Werkzeugordner `node/`, Werkzeugprofil, `/opt/homebrew/bin/node`, `/usr/local/bin/node` | die Version REAs `engines.node` erfüllt (REA 6.8: `^22.23.4 \|\| ^24.22.1 \|\| >=26.12.1`) |
| REA | Werkzeugordner `rea/node_modules/rea-agents`, Werkzeugprofil | Version 6.5.0 oder neuer und Fridas native Komponente (`frida_binding.node`) vorhanden ist |
| JADX headless MCP | Werkzeugordner `jadx/`, Werkzeugprofil | sein SHA-256 zu dem Release passt, das das installierte REA in `dist/android/JadxRelease.js` vorgibt |
| Frida-Java-Bridge | Werkzeugordner `frida-bridge/java-bridge.bundle.js`, Werkzeugprofil | die Datei vorhanden ist |
| frida-server | Werkzeugordner `frida-server/` | ein Binary für die Emulator-Architektur (arm64 auf Apple Silicon) mit genau der Frida-Version vorliegt, die REA verwendet |
| Android SDK | der gewählte SDK-Ordner | `adb`, `emulator`, `aapt2`, `apkanalyzer`, `avdmanager` und `sdkmanager` alle vorhanden sind |

**Erneut prüfen** wiederholt die Prüfung. Nach jeder Prüfung richtet die App ihr Werkzeugprofil auf die bereiten Werkzeuge aus, sodass die Codeanalyse sie ohne weitere Schritte verwendet.

## Installation

Zuerst einen Werkzeugordner wählen. Vorgeschlagen wird `analyxer-tools` neben dem SDK-Ordner; jeder Ordner ist möglich, etwa auf einer externen Platte. **Installieren …** (oder **Aktualisieren …**, **Reparieren …**) zeigt Quelle und Größe und startet erst nach Bestätigung. **Alles Fehlende installieren …** installiert alle fehlenden Werkzeuge außer dem Android SDK in der richtigen Reihenfolge.

| Werkzeug | Quelle | Prüfung | Größe |
|---|---|---|---|
| JDK 25 | Eclipse Temurin über die [Adoptium-API](https://api.adoptium.net) | SHA-256 aus der API | etwa 130 MB |
| Node.js 24.22.2 | [nodejs.org](https://nodejs.org/dist/) | `SHASUMS256.txt` | etwa 50 MB |
| REA 6.8.0 | npm (`rea-agents`); Fridas native Komponente lädt danach Fridas eigenes Installationsskript | npm-Integritätsprüfung | etwa 220 MB plus 36 MB |
| JADX headless MCP | das GitHub-Release, auf das REA verweist | SHA-256 aus REA | etwa 42 MB |
| frida-java-bridge 7.0.13 | npm, lokal mit REAs Frida-Compiler gebaut | npm-Integritätsprüfung | etwa 1 MB |
| frida-server | [Fridas GitHub-Releases](https://github.com/frida/frida/releases), passend zu REAs Frida-Version | SHA-256-Digest aus der GitHub-API | etwa 17 MB |
| Android SDK | Googles Command-line-Tools aus `repository2-3.xml`, danach `sdkmanager` | SHA-1 aus Googles Repository, danach `sdkmanager` | etwa 150 MB plus die Pakete |

Jeder Download verwendet HTTPS. Ein Download mit abweichender Prüfsumme wird gelöscht, und nichts wird entpackt. Archive werden in einen Zwischenordner entpackt und erst danach an ihren Platz verschoben; ein fehlgeschlagenes Update lässt die vorherige Version also unverändert. npm läuft mit `--ignore-scripts` und einem eigenen Cache im Werkzeugordner; das einzige Installationsskript, das REA braucht (Fridas native Komponente), wird danach ausdrücklich ausgeführt.

### Android SDK

**Einrichten …** (oder **Pakete hinzufügen …**, wenn das SDK bereits vollständig ist) öffnet ein Blatt, das Zielordner und Pakete nennt: `platform-tools`, `emulator`, `build-tools;36.1.0`, `platforms;android-36` und optional ein Google-Play-Systemimage (`system-images;android-36.1;google_apis_playstore;arm64-v8a` auf Apple Silicon, etwa 2 GB). **Lizenzen anzeigen** lädt Googles Lizenztexte; dafür wird ein JDK gebraucht, fehlende Command-line-Tools werden heruntergeladen, angenommen wird dabei nichts. **Lizenzen annehmen und installieren** nimmt sie an und installiert die Pakete.

### frida-server

Die Werkzeugverwaltung lädt frida-server in den Werkzeugordner. Sie kopiert ihn nicht auf ein Gerät: Die Prozessbeobachtung benötigt ein vorbereitetes Analysegerät, auf dem frida-server läuft; siehe [Code- und Datenflussanalyse](deep-analysis.md).

## Werkzeugprofil

Die App hält die verwendeten Pfade in einem Werkzeugprofil fest. Die Einrichtung füllt es automatisch. Für die Kommandozeile oder um Werkzeuge an anderen Orten zu verwenden, kann ein Profil auch eine kleine JSON-Datei sein; **Werkzeugprofil laden …** im Codeanalyse-Abschnitt eines Projekts liest eine solche Datei:

```json
{
  "executable": "/absolute/path/node",
  "cliScript": "/absolute/path/rea-agents/scripts/rea.mjs",
  "jadxJAR": "/absolute/path/jadx-headless-mcp-0.7.1-all.jar",
  "javaHome": "/absolute/path/jdk/Contents/Home",
  "javaBridge": "/absolute/path/java-bridge.bundle.js"
}
```

Das Profil enthält nur Programmpfade, keine Zugangsdaten. Ein eigenständiges REA-Programm kann ohne `cliScript` verwendet werden; leere optionale Pfade werden als leere Strings gespeichert.

## Kommandozeile

Dieselbe Werkzeugverwaltung steht in der CLI zur Verfügung:

```sh
swift run --disable-sandbox android-analyxer-cli setup check --tools /Volumes/Data/analyxer-tools
swift run --disable-sandbox android-analyxer-cli setup install frida-server --tools /Volumes/Data/analyxer-tools --profile tools.json
swift run --disable-sandbox android-analyxer-cli setup licenses --sdk /Volumes/Data/android-sdk
swift run --disable-sandbox android-analyxer-cli setup install android-sdk --sdk /Volumes/Data/android-sdk --accept-android-licenses
```

Werkzeuge: `jdk`, `node`, `rea`, `jadx`, `frida-bridge`, `frida-server`, `android-sdk` oder `all`. `--profile` liest ein vorhandenes Werkzeugprofil, damit Werkzeuge außerhalb des Werkzeugordners zählen. `--play-image` fügt das Google-Play-Systemimage hinzu. `install android-sdk` verweigert den Start, bis die Lizenzen angenommen sind, entweder vorher oder mit `--accept-android-licenses`, nachdem sie mit `setup licenses` gelesen wurden.

## Lizenzen

Jedes Werkzeug steht unter seiner eigenen Lizenz; siehe [Hinweise zu Fremdwerkzeugen](../../THIRD_PARTY_NOTICES.md) (englisch). Die Lizenz des Android SDK musst du selbst annehmen.
