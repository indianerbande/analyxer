# Google-Play-Geräte

[English](../google-play.md)

## Ein Play-Gerät verwenden

1. Android Analyxer öffnen, **Geräte** auswählen und unter **Google-Play-Gerät anlegen** ein Gerät aus einem installierten offiziellen Google-Play-Systemimage erstellen (Tablet oder Telefon).
2. **Änderungen dauerhaft speichern** eingeschaltet lassen und das Gerät starten. Android öffnet sich in einem eigenen Emulatorfenster.
3. Wenn Android gestartet ist, **Google Play öffnen** wählen. Im Android-Fenster mit dem eigenen Google-Konto anmelden und Apps aus dem Store installieren. Google kann zunächst seine System-Apps aktualisieren.
4. **Installierte Apps → Apps laden**. Nach Paketname filtern und **Untersuchen …** wählen. Einen neuen `.androidlab`-Ordner speichern.
5. Der Import sichert die Basis-APK und alle aktuell installierten Split-APKs, analysiert das Basis-Manifest und prüft die vorhandene Installation. **Projekt-App starten**, App bedienen, Screenshots und Logcat speichern oder unter **Code und Datenflüsse untersuchen** eine APK an REA übergeben.
6. Nach einem Neustart oder erneutem Öffnen eines Projekts eine neue Testsitzung beginnen und **Installierte App zuordnen** wählen. Nach einem App-Update neu importieren, wenn die Hashes nicht mehr übereinstimmen.

Die laufende Store-App wird beim Import nicht ersetzt. Konten und App-Daten liegen im dauerhaften AVD, nicht im Analyseprojekt. Der temporäre Modus verwirft Änderungen beim Beenden des Emulators. Beide Modi starten mit `-no-snapshot -no-metrics`; dauerhafte Benutzerdaten benötigen keine Snapshots.

## Geräteverwaltung

**Google-Play-Gerät anlegen** verwendet ausschließlich lokal installierte, nicht als Preview markierte Telefon-Systemimages mit `google_apis_playstore` und der Hostarchitektur. Ein neues Gerät kann ein Tablet (Pixel-Tablet-Profil, 1920×1200 bei 240 dpi, Querformat) oder ein Telefon (Pixel 6) sein; vorgewählt ist Tablet. Neue AVDs entstehen in dem unter **Einrichtung → Eigene Geräte** gewählten Ordner (Standard: `avd` neben dem SDK-Ordner). Bestehende Namen werden abgewiesen; es gibt kein `--force` und kein Zurücksetzen bestehender Geräte.

**Geräte** zeigt eigene Geräte und Android-Studio-Geräte (Standard-Katalog, z. B. `~/.android/avd`) in getrennten Abschnitten. Jede Karte zeigt das System, gelesen aus `target` in `<Name>.ini`, sowie Variante und Architektur aus `config.ini`. Zeigen beide Kataloge auf denselben Ordner, erscheint jedes Gerät nur einmal.

- **Umbenennen** ist nur für eigene, gestoppte Geräte möglich. Angepasst werden `<Name>.avd`, `<Name>.ini` samt Pfad, `AvdId` und `avd.ini.displayname` in `config.ini` sowie `hardware-qemu.ini`. Der neue Name darf in keinem der beiden Kataloge vergeben sein. Schlägt etwas fehl, wird der vorherige Zustand wiederhergestellt. Apps, Anmeldung und Daten bleiben erhalten.
- **Löschen** ist nur für eigene, gestoppte Geräte möglich und fragt vorher nach. `.avd`-Ordner und `.ini` gehen in den Papierkorb, sofern die `.ini` auf genau diesen Ordner zeigt.
- **Android-Studio-Geräte** lassen sich starten und steuern, aber nur in Android Studio löschen.

Die App bündelt weder SDK noch JDK noch Systemimages. Ein fehlendes Play-Image über **Einrichtung → Analysewerkzeuge → Android SDK** (optionales Play-Image) oder den Android-Studio-SDK-Manager installieren.

### Tastatur

Neue Geräte aktivieren die Mac-Tastatur (`hw.keyboard=yes`, `hw.keyboard.lid=no`). **Bildschirmtastatur aktivieren** schaltet Androids normale Bildschirmtastatur zusätzlich zur Hardware-Tastatur ein und deaktiviert die automatische Stift-Handschrifteingabe (`show_ime_with_hard_keyboard=1`, `stylus_handwriting_enabled=0`, dokumentiert im [Android-16-Quellcode](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r2/core/java/android/provider/Settings.java)). Ein bereits offener Handschriftmodus muss gegebenenfalls über dessen Menü verlassen oder das Gerät neu gestartet werden. Der Knopf prüft beide geschriebenen Werte und verändert keine Tastatur-App-Daten.

### Tablet-Layout

Tablets verwenden 1920×1200 Pixel bei 240 dpi im Querformat. Android meldet dann `sw800dp`, `w1280dp`, `h800dp`, `xlarge`, `land`. Gegenüber einem Telefon unterscheiden sich nur die Display- und Skin-Einstellungen des AVDs.

## Was geprüft ist

Geprüft mit dem offiziellen Play-Image API 36.1 (ARM64): Store-Start bis zur sichtbaren Anmeldung, Installation der eigenen Test-App des Projekts, kalter Neustart aus der App und Erhalt beider installierten Test-APKs. CLI und GUI importieren die Basis-APK und einen signierten Ressourcen-Split; Hashabgleich, Start ohne Neuinstallation und vollständiger Export funktionieren. Die automatisierten Tests decken Abbruch bei Update oder Neustart, falsche Split-Paketkennung, Manipulation und Schema-3-Roundtrip ab.

**Noch nicht geprüft:** Anmeldung mit einem Benutzerkonto, tatsächlicher Store-Download, Kontopersistenz und Store-Updates. Diese Schritte benötigen die Anmeldung durch den Benutzer. APK-Satz-Import ist mit der eigenen signierten Test-App des Projekts geprüft, nicht mit einer aus einem angemeldeten Store heruntergeladenen Drittanbieter-App.

## Grenzen

Offizielle Google-Play-Images ermöglichen kein `adb root` ([Android-Dokumentation](https://developer.android.com/studio/run/managing-avds)). Codeanalyse mit REA, APK-Import, Screenshots und zugängliche App-Logs funktionieren ohne Root. Frida-Prozessbeobachtung setzt ein vorbereitetes Analysegerät voraus. Die App bietet hierfür an, den vollständigen importierten APK-Satz dort zu installieren; für passende ABI und API-Stufe, Abhängigkeiten und die Lauffähigkeit der App auf diesem Gerät bist du selbst verantwortlich.

Ein installierter APK-Satz enthält nur die für dieses Gerät installierten Komponenten. Nachgeladene Features, zusätzliche Dateien, private App-Daten und andere Architekturen eines App Bundles sind nicht enthalten. Die Übersicht beschreibt die Basis-APK; REA analysiert die gewählte APK. Der Netzwerkmitschnitt bleibt auf die dokumentierten Aufnahmepfade begrenzt.

Quellen: [Create and manage virtual devices](https://developer.android.com/studio/run/managing-avds) für Play-Store-Profile, Systemimages und Root-Grenzen; [Start the emulator from the command line](https://developer.android.com/studio/run/emulator-commandline) für Start und Benutzerdaten.
