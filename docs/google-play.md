# Google Play · v0.4

## Bedienung

1. Android Analyxer öffnen, **Geräte** auswählen und unter **Google-Play-Gerät anlegen** ein Gerät aus einem installierten offiziellen Google-Play-Image erstellen (Tablet oder Telefon).
2. **Änderungen dauerhaft speichern** eingeschaltet lassen und dieses Gerät starten. Android öffnet sich in einem eigenen Emulatorfenster.
3. Wenn Android gestartet ist, **Google Play öffnen** wählen. Im Android-Fenster mit dem eigenen Google-Konto anmelden und Apps aus dem Store installieren. Google kann zunächst seine System-Apps aktualisieren.
4. **Installierte Apps → Pakete laden**. Nach Paketkennung filtern und **Untersuchen …** wählen. Einen neuen `.androidlab`-Ordner speichern.
5. Der Import sichert Basis und alle aktuell installierten Split-APKs, analysiert das Basis-Manifest und prüft die vorhandene Installation. **Projekt-App starten**, App bedienen, Screenshots/Logcat speichern oder unter **Code und Datenflüsse** eine APK an REA übergeben.
6. Nach Neustart oder erneutem Öffnen eines Projekts eine neue Testsitzung beginnen und **Installierte App zuordnen** wählen. Nach einem App-Update bei Hashabweichungen neu importieren.

Die laufende Store-App wird beim Import nicht ersetzt. Konten und App-Daten liegen im dauerhaften AVD, nicht im Analyseprojekt. Temporärer Modus verwirft Änderungen beim Beenden. Ein Start schaltet weder Snapshots noch Emulator-Metriken ein.

## Geräteverwaltung

**Google-Play-Gerät anlegen** verwendet ausschließlich lokal installierte, nicht als Preview markierte Telefon-Systemimages mit `google_apis_playstore` und passender Hostarchitektur. Bei neuen Geräten sind Tablet (Pixel-Tablet-Profil, 1920×1200 bei 240 dpi) und Telefon (Pixel 6) auswählbar; die Oberfläche wählt Tablet vor. Neue AVDs entstehen im unter **Einrichtung → Eigene Geräte** gewählten Ordner (Standard `<SDK-Elternordner>/avd`); bestehende Namen werden abgewiesen, kein `--force`, kein Zurücksetzen bestehender Geräte. Umbenennen ist nur für eigene, gestoppte Geräte möglich: `<Name>.avd`, `<Name>.ini` samt Pfad, `AvdId` und `avd.ini.displayname` in `config.ini` sowie `hardware-qemu.ini` werden angepasst; der neue Name darf weder hier noch im Android-Studio-Katalog vergeben sein, ein Fehler stellt den vorherigen Zustand wieder her. Löschen ist ebenfalls nur für eigene, gestoppte Geräte möglich: `.avd`-Ordner und `.ini` gehen in den Papierkorb, sofern die `.ini` auf genau diesen Ordner zeigt; Android-Studio-Geräte werden nie gelöscht. Der native UI-Start verwendet denselben eigenen Katalog. SDK, JDK und Images werden nicht gebündelt oder automatisch heruntergeladen; fehlende Images sind über den Android-Studio-SDK-Manager zu installieren.

## Was geprüft ist

Geprüft mit dem offiziellen Play-Image API 36.1 (ARM64): Store-Start bis zur sichtbaren Anmeldung, Installation der eigenen Test-App, kalter Neustart über die native App und Erhalt beider installierten Test-APKs. CLI und GUI importieren Basis und signierten Ressourcen-Split; Hashabgleich, App-Start ohne Neuinstallation sowie vollständiger Export funktionieren. Die automatisierten Tests decken Update-/Neustart-Abbruch, falsche Split-Paketkennung, Manipulation und Schema-3-Roundtrip ab.

**Noch nicht geprüft:** Anmeldung mit einem Benutzerkonto, tatsächlicher Store-Download, Kontopersistenz und Store-Updates. Diese Schritte benötigen die Anmeldung durch den Benutzer. APK-Satz-Import ist mit der eigenen signierten Test-App geprüft, nicht mit einer aus einem angemeldeten Store heruntergeladenen Drittanbieter-App.

## Grenzen der Untersuchung

Offizielle Google-Play-Images ermöglichen kein `adb root`. Codeanalyse mit REA, APK-Import, Screenshots und zugängliche App-Logs funktionieren ohne Root. Frida-Prozessbeobachtung setzt ein vorbereitetes Analysegerät voraus. Die App bietet hierfür die Installation des vollständigen importierten APK-Satzes an; passende ABI/API, Abhängigkeiten und die Laufzeitfähigkeit der App müssen dort gegeben sein.

Ein installierter APK-Satz enthält nur die für dieses Gerät installierten Komponenten. Nachgeladene Features, zusätzliche Dateien, private App-Daten und andere Architekturen eines App Bundles sind nicht automatisch enthalten. Die Hauptübersicht beschreibt die Basis-APK; REA analysiert die einzeln gewählte APK. Netzwerkaufzeichnung bleibt auf die dokumentierten Aufnahmepfade begrenzt.

Quellen: [Offizielle AVD-Dokumentation](https://developer.android.com/studio/run/managing-avds) für Play-Store-Profile, Systemimages und Root-Grenzen; [Emulator-Befehle](https://developer.android.com/studio/run/emulator-commandline) für Start und Benutzerdaten.

## Tastaturkorrektur · v0.4.1

Neue Geräte aktivieren die Mac-Tastatur (`hw.keyboard=yes`, `hw.keyboard.lid=no`). Unter **Geräte → Bildschirmtastatur aktivieren** lässt sich Androids normale Tastenansicht auch zusammen mit der Hardware-Tastatur einschalten; die automatische Stift-Handschrifteingabe wird dabei deaktiviert. Ein bereits offener Handschriftmodus muss gegebenenfalls über dessen Menü verlassen oder das Gerät neu gestartet werden.

Technische Einstellungen: `show_ime_with_hard_keyboard=1`, `stylus_handwriting_enabled=0`. Letztere ist im [Android-16-Quellcode](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r2/core/java/android/provider/Settings.java) dokumentiert. Der Knopf prüft beide geschriebenen Werte und verändert keine Tastatur-App-Daten.

## Tablet-Layout · v0.4.2

Geräte im Format **Tablet** verwenden 1920×1200 Pixel bei 240 dpi im Querformat. Android meldet dann `sw800dp`, `w1280dp`, `h800dp`, `xlarge`, `land`. Das Format wird beim Anlegen über **Geräteformat → Tablet / Telefon** gewählt; geändert werden ausschließlich Display- und Skin-Einstellungen des AVDs.
