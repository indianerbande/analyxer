# Android Analyxer

Native macOS-Arbeitsumgebung für Android-Emulatoren, APK-Analyse und Gerätepflege. Version 0.4 mit dauerhaften Google-Play-Geräten, Steckbrief für jede untersuchte App, Import installierter APK-Sätze, REA-Codeanalyse und gezielter Prozessinstrumentierung. Eigene SwiftUI-Oberfläche, der Emulator des Android SDK als Laufzeit.

## Starten

Die lokal gebaute App liegt unter `dist/Android Analyxer.app`. `scripts/build-app.sh` ersetzt danach jedes Mal auch `/Applications/Android Analyxer.app` durch den neuen Build.

```sh
scripts/build-app.sh
open '/Applications/Android Analyxer.app'
```

Voraussetzungen: macOS 14+, Xcode mit Swift 6+, Android SDK mit `emulator`, `platform-tools`, `build-tools`, `cmdline-tools` (APK Analyzer), einer funktionierenden lokalen Java-Laufzeit und mindestens einem passenden AVD. Getestet auf Apple Silicon mit ARM64-Images von Android 14 bis 16. Intel-Macs sind nicht getestet.

SDK-Erkennung: `ANDROID_HOME`, danach `ANDROID_SDK_ROOT`, sonst `~/Library/Android/sdk`. Im UI lässt sich der SDK-Ordner ändern. Google-Play-Geräte legt die App selbst an; andere Geräte entstehen in Android Studio → Device Manager.

## Arbeitsablauf

1. **APK öffnen:** neuen Projektordner wählen; die App kopiert und analysiert die APK.
2. **Analyseprojekte:** Manifest-Komponenten, Berechtigungen, Hash und DEX-Inventar prüfen.
3. **Geräte:** Emulator starten; anschließend im Projekt eine Testsitzung für das Zielgerät beginnen.
4. **Im Projekt testen:** APK installieren, Projekt-App starten, navigieren, App-Logcat und Screenshots speichern.
5. **Notizen und Export:** Beobachtungen sichern, Sitzung beenden und das gesamte Projekt exportieren oder später wieder öffnen.

Alle Projektaktionen werden sofort gespeichert. Statische Befunde und Laufzeitbeobachtungen bleiben getrennt. Einzelwerkzeuge außerhalb des Projektbereichs zeichnen nicht automatisch im Projekt auf. Details: [Projektablauf und Dateiformat](docs/project-workflow.md).

Emulatoren starten standardmäßig dauerhaft: Apps und Anmeldung bleiben erhalten. Der Schalter **Änderungen dauerhaft speichern** kann für eine temporäre Testsitzung ausgeschaltet werden (`-read-only`). Beide Modi verwenden `-no-snapshot -no-metrics`; dauerhafte Benutzerdaten benötigen keine Snapshots. Die macOS-App lädt keine APKs in eine Cloud hoch; Android, Google Play und installierte Apps verwenden ihre eigenen Netzwerkverbindungen.

### Google Play verwenden

Unter **Geräte → Google-Play-Gerät anlegen** entsteht aus einem installierten offiziellen Google-Play-Image ein eigenes Gerät (Tablet oder Telefon). Es in **Geräte** starten, danach **Google Play öffnen** und im Android-Fenster selbst anmelden. Nach der Store-Installation unter **Installierte Apps → Pakete laden → Untersuchen …** die gewünschte App in ein Analyseprojekt übernehmen. Es enthält Basis-APK und alle zu diesem Zeitpunkt installierten Splits. Die App wird dafür nicht neu installiert; ein Hashabgleich ordnet die vorhandene Installation einer Testsitzung zu.

Den Ordner für die eigenen AVDs legt **Einrichtung → Eigene Geräte** fest; ohne Auswahl gilt `<SDK-Elternordner>/avd`, also ein Ordner `avd` neben dem SDK. Unter **Geräte** stehen eigene Geräte und Android-Studio-Geräte (Standard-Katalog, z. B. `~/.android/avd`) in getrennten Abschnitten. Jede Karte zeigt das System des Geräts, etwa „Android 16 · API 36.1 · Google Play · ARM64“, gelesen aus `target` in `<Name>.ini` sowie Variante und Architektur aus der `config.ini`. Eigene Geräte lassen sich umbenennen und nach einer Rückfrage löschen; beim Löschen wandern sie in den Papierkorb, laufende Geräte werden in beiden Fällen abgewiesen. Umbenennen ändert Ordner, Katalogeintrag und `AvdId`; Apps, Anmeldung und Daten bleiben erhalten. Android-Studio-Geräte lassen sich starten und steuern, aber nur in Android Studio löschen. Zeigen beide Kataloge auf denselben Ordner, erscheint jedes Gerät nur einmal. Siehe [Google-Play-Ablauf und Prüfgrenzen](docs/google-play.md).

### Steckbrief einer App

Jedes Analyseprojekt beginnt mit einem Steckbrief in Klartext: Android-Version (ab/für), Umfang, Technik (z. B. Unity mit IL2CPP, Flutter, React Native), Architekturen und Herkunft. Darunter stehen Auffälligkeiten auf einen Blick (Werbe-ID, Sonderzugriffe wie Overlay oder exakte Wecker, unverschlüsseltes HTTP, Debug-Build, Emulator-Erkennung u. a.), die Berechtigungen nach Themen mit Androids Einstufung (Freigabe nötig, Sonderzugriff, ohne Rückfrage, nur Systemapps, Hersteller, App-intern), die erkannten Bibliotheken nach Zweck (Werbung, Analyse & Attribution, Absturzberichte, Einwilligung, Login, Zahlungen, Push, Kundenservice, Schutz & Erkennung u. a.) und was von außen erreichbar ist (Komponenten, Weblinks, eigene Link-Schemata).

Bibliotheken werden an Manifest-Komponenten, nativen Bibliotheken (`lib/*/*.so`), Bibliothekskennungen (`*.properties`, `META-INF/*.version`) und, soweit vorhanden, am DEX-Inventar erkannt. Das gespeicherte DEX-Inventar ist bei großen Apps abgeschnitten; der Steckbrief sagt das dazu. Erkannt wird, was eingebunden ist, nicht, ob oder wie es zur Laufzeit genutzt wird. Hash, Werkzeugbericht, Manifest, DEX-Inventar und alle Komponenten liegen eingeklappt unter **Details & Belege**; die Berichtsvorschau zeigt auch große Dateien vollständig und durchsuchbar (⌘F).

### Gerätepflege

**Installierte Apps** zeigt alle Apps des ausgewählten Geräts mit Speicherbedarf (App, Daten, Cache), Herkunft (Play Store, vorinstalliert, Sideload, ADB) und letzter Nutzung; filterbar nach selbst installiert, vorinstalliert, deaktiviert und entfernt, sortierbar nach Größe, Name oder Nutzung. Pro App: deaktivieren oder aktivieren; vorinstallierte Apps für den Benutzer entfernen und wiederherstellen; selbst installierte Apps mit allen Daten deinstallieren. Alles Verändernde fragt vorher nach. Systemkomponenten, Play-Dienste, Play Store, aktueller Launcher, Tastatur und WebView sind gesperrt.

**Gerätepflege** zeigt den Speicher (belegt, frei, Apps, App-Daten, Caches, Bilder, Videos, Audio, Downloads), leert auf Wunsch alle App-Caches (`pm trim-caches`) und findet Ordner deinstallierter Apps in `Android/data`, `obb` und `media`; diese lassen sich nach Rückfrage endgültig löschen.

Alles läuft über ADB, ohne Root und ohne App auf dem Gerät. Für aktuelle Größen stößt die Analyse Androids täglichen Speicherstatistik-Job einmal an (`cmd jobscheduler run -f`). Cache-Leeren pro App ist nicht möglich, weil `pm clear --cache-only` auf Android 16 hängt. App-Namen erscheinen als Paketnamen.

## Entwicklung und Tests

Keine Swift-Abhängigkeiten von Drittanbietern.

```sh
CLANG_MODULE_CACHE_PATH=/tmp/android-analyxer-clang-cache swift test --disable-sandbox
swift run --disable-sandbox android-analyxer-cli diagnose
swift run --disable-sandbox android-analyxer-cli care emulator-5554
swift run --disable-sandbox android-analyxer-cli profile analysis-projects/mein-projekt.androidlab
scripts/build-fixture.sh
swift run --disable-sandbox android-analyxer-cli inspect .local/fixture/android-analyxer-fixture.apk
```

`--disable-sandbox` betrifft den Swift-Paketmanifest-Prozess, nicht macOS-Systemschutz. Die gebaute App ist lokal ad-hoc signiert, nicht notarisiert. Distribution, Updater und automatische SDK-Installation sind nicht eingerichtet.

Die Test-APK wird vollständig aus `fixture/` mit dem vorhandenen SDK gebaut. Im normalen Start schreibt sie einen Zähler und Logcat-Nachrichten. Der ausdrücklich aktivierte TLS-Test verwendet ausschließlich synthetische Daten und den lokalen Testserver; Details in [Code- und Datenflussanalyse](docs/deep-analysis.md). Ein End-to-End-Test auf einem ausdrücklich gewählten, entbehrlichen Emulator:

```sh
swift run --disable-sandbox android-analyxer-cli smoke emulator-5580 \
  .local/fixture/android-analyxer-fixture.apk .local/smoke
```

`care SERIAL` gibt Speicher, die größten Apps und App-Reste aus und ändert nichts. `care-smoke EMULATOR-SERIAL` führt jede Pflegeaktion einmal aus (YouTube deaktivieren, aktivieren, für Benutzer entfernen, wiederherstellen; Caches leeren; künstlichen App-Rest anlegen und löschen) und ist nur für einen entbehrlichen Emulator gedacht.

Der Smoke-Test akzeptiert ausschließlich `lab.androidanalyxer.fixture`, installiert und startet sie auf genau diesem Emulator und exportiert Paketliste, Manifestdaten, Logcat und Screenshot. Bestehende private Geräte sind dafür nicht vorgesehen.

## Aufbau und offene Arbeit

Die Google-Play-Basis ist in v0.4 umgesetzt: eigene Geräte anlegen, dauerhaft/temporär starten, Store öffnen und installierte Apps mit Splits importieren. Store-Anmeldung und tatsächlicher Download mit einem Benutzerkonto stehen noch aus. Start, Persistenz installierter APKs, GUI-Import, Zuordnung und Export wurden lokal geprüft.

Google-Play-Geräte erlauben laut [Android-Dokumentation](https://developer.android.com/studio/run/managing-avds) kein `adb root`. Statische REA-Untersuchung, Screenshots und App-Logcat sind auf diesen Geräten möglich; die Prozessinstrumentierung benötigt weiterhin ein vorbereitetes separates Analysegerät.

### Ziel der Analysefunktionen

Die Analyse hat zwei verbindliche Schwerpunkte: **APKs unmittelbar an REA zur Codeuntersuchung übergeben** und **Datenströme während der App-Ausführung untersuchen**. Manifestberichte, Logcat und Screenshots sind dafür unterstützende Befunde, aber noch keine Umsetzung dieser beiden Schwerpunkte.

- **APK → REA:** dieselbe unveränderte Projekt-APK mit Hash übergeben; Klassen, Methoden, Referenzen, Ressourcen und gegebenenfalls native Bibliotheken untersuchen. REA-Befunde mit Evidence-IDs, Werkzeugversionen und Abdeckungsgrenzen wieder im Projekt speichern. Die vorhandene Android-Schnittstelle benötigt einen separat eingerichteten JADX-MCP-Provider und ein vollständiges JDK. Native Bibliotheken benötigen einen passenden nativen Provider. Importierte Store-Apps enthalten den vollständigen aktuell installierten APK-Satz. In der Codeanalyse lässt sich die zu untersuchende Basis- oder Split-APK auswählen; ein APK-Satz ist kein vollständiges ursprüngliches App Bundle.
- **Laufzeit → Netzwerkaufzeichnung → Untersuchung:** Zielverbindungen, Zeitpunkte, Datenmengen und Protokolle erfassen; Requests, Responses und Nutzdaten anzeigen, soweit tatsächlich zugänglich. Paketmitschnitt und HTTP-Analyseproxy sind eigene Aufnahmebausteine; REA untersucht anschließend unterstützte gespeicherte Aufzeichnungen. Mitschnitte können auch Verkehr von Android und Google-Diensten enthalten: eine Zuordnung zur untersuchten App braucht zusätzliche Belege und darf nicht allein aus zeitlicher Nähe abgeleitet werden.
- **Zusammenführung:** Codefundstellen, Bedienaktionen und Netzwerkbefunde in derselben Testsitzung verknüpfen. Statisch gefundene Endpunkte bleiben Kandidaten, bis ihre Verwendung beobachtet wurde. Verschlüsselte oder nicht erfasste Inhalte ausdrücklich als unbekannt markieren.

Der SDK-Emulator bietet Paketaufzeichnung über `-tcpdump`. HTTPS-Inhalte werden dadurch nicht entschlüsselt; auch ein Proxy macht sie nicht automatisch lesbar. Zertifikatsvertrauen und Pinning können die Inhaltsanalyse begrenzen. Quellen: [Emulator-Befehle](https://developer.android.com/studio/run/emulator-commandline), [Android-Netzwerksicherheit](https://developer.android.com/privacy-and-security/security-config).

In v0.3 sind REA/JADX, gezielte Java-Methodenbeobachtung über REA/Frida, Legacy-WAN-Aufzeichnung und ein eigener PCAP-Metadatenparser integriert. Der echte lokale HTTPS-Test belegt Eingaben und Rückgaben im App-Prozess vor Versand und nach Entschlüsselung. Die Geräte-/Provider-Voraussetzungen, Grenzen und Bedienung stehen in [Code- und Datenflussanalyse](docs/deep-analysis.md).

- `Sources/AndroidAnalyxer`: SwiftUI-Oberfläche.
- `Sources/AndroidAnalyxerCore`: SDK-/Prozessadapter, statische Analyse, Projektablage und Testsitzungen.
- `Sources/AndroidAnalyxerCLI`: Diagnose und Integrationstest.
- `Tests`: 80 gezielte Tests ohne private Android-Geräte, einschließlich Projekt-Roundtrip, Integrität, Pfadvalidierung und Geräte-Neustart.
- `docs/`: Projektablauf und Dateiformat, Google-Play-Geräte, Code- und Datenflussanalyse.

Offen bleiben insbesondere AVD-Klonen, eingebettetes Android-Bild, Keymapping/Gamepad, Snapshotverwaltung, native/JNI-Messpunkte und vollständige WLAN-Aufzeichnung. Google-Play-Alltagsprofile und instrumentierbare Analyseprofile müssen als eigene Gerätemodi weiter ausgebaut werden.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Externe Werkzeuge wie Android SDK, JDK, Node.js, REA, JADX und Frida sind nicht enthalten und stehen unter eigenen Lizenzen; siehe [Fremdwerkzeuge](THIRD_PARTY_NOTICES.md).
