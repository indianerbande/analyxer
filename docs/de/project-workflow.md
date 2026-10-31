# Analyseprojekte

[English](../project-workflow.md)

Ein Projekt verbindet genau eine App-Version (einzelne APK oder installierter Basis-/Split-Satz) mit statischen Befunden und beliebig vielen dokumentierten Testsitzungen. Die APK wird beim Anlegen kopiert. Die Analyse, spätere Installation und der Export verwenden diese Kopie; das Original kann danach verschoben werden.

## Ablauf

1. **APK öffnen … / Neues Projekt aus APK …:** APK auswählen, neuen Projektordner festlegen. Der Ordner darf noch nicht existieren. Die Endung `.androidlab` ist eine Namenskonvention; das Projekt ist ein normaler Ordner.
2. **Steckbrief:** Das Projekt öffnet mit einem Steckbrief in Klartext (Versionen, Umfang, Technik, Berechtigungen, Bibliotheken, was von außen erreichbar ist). Bericht, vollständiges Manifest, DEX-Inventar und alle Komponenten liegen unter **Details & Belege**. Komponenten lassen sich nach Namen und Typ filtern. `exported` wird als expliziter Manifest-Wert gezeigt; ein fehlender Wert wird nicht als `false` interpretiert.
3. **Testsitzung beginnen:** vollständig gestartetes Android-Gerät auswählen. Gerätekennung, AVD-Name (wenn verfügbar), Android- und SDK-Version, ABI, Modell, Build-Fingerprint, Boot-ID und ADB-Version werden gespeichert.
4. **Projekt-APK installieren → Projekt-App starten:** Nur die Projekt-APK wird installiert und nur ihr Paket gestartet. Ein Start im Projekt benötigt eine bestätigte Installation derselben Sitzung.
5. **Beobachten:** Screenshots aufnehmen, App-Logcat speichern und über den Projektbereich navigieren. Erfolgreiche Aktionen und Fehler werden sofort als getrennte Befunde gespeichert. **Notiz speichern** sichert die eigenen Notizen.
6. **Sitzung beenden / später fortsetzen:** Projekt erneut öffnen; frühere Befunde bleiben sichtbar. Laufzeitaktionen benötigen eine neue, ausdrücklich begonnene Sitzung. Ein Gerätetausch oder Android-Neustart bei gleicher ADB-Seriennummer wird über die Boot-ID erkannt.
7. **Gesamtexport …:** neuen Zielordner wählen. Er enthält die APKs, den Projektindex, alle referenzierten Befunddateien und `report.txt` mit statischem Bericht, Sitzungsdaten, Aktionen und Notizen. Der Export kann wieder als Projekt geöffnet werden.

Die Seiten Geräte, Installierte Apps und Logcat bleiben eigene Werkzeuge. Nur Aktionen im Bereich **Analyseprojekte** werden automatisch in einem Projekt aufgezeichnet. Screenshots zeigen den gesamten Gerätebildschirm. App-Logcat wird auf den aktuellen Hauptprozess gefiltert, erfasst keine Nebenprozesse und ist eine begrenzte Momentaufnahme; ältere Einträge derselben PID können enthalten sein.

Dateien, die ins Projekt geschrieben werden (Berichte, Befundzusammenfassungen, `report.txt`), sind unabhängig von der Sprache der Oberfläche immer englisch, damit ein Projekt überall gleich lesbar ist. Projekte älterer Versionen behalten ihre vorhandenen Texte.

## Ablage und Integrität

```text
Example.androidlab/
  project.json                 # Schema 1/2/3, Revision, APK-Identität, Analyse, Sitzungen, Befundindex
  input/application.apk        # eigene APK-Kopie des Projekts
  input/split-1.apk            # optional: weitere APKs, jeweils mit SHA-256
  evidence/<UUID>.txt          # Berichte, DEX, Aktionen, Logs, Notizen, Fehler
  evidence/<UUID>.xml          # dekodiertes Manifest
  evidence/<UUID>.png          # Screenshots
  .write-lock                  # lokale Schreibkoordination; nicht im Export
  report.txt                   # zusätzlicher Gesamtbericht im Export
```

Zeitstempel werden in UTC/ISO 8601 gespeichert und in lokaler Zeit angezeigt. Jeder Befund ist an einen Zeitstempel, einen SHA-256 und optional eine Testsitzung gebunden. Statische Berichte sind nicht als Laufzeitbeobachtungen gekennzeichnet.

- Anlegen und Export geschehen in einem neuen temporären Nachbarordner, der erst nach erfolgreichem Abschluss an das Ziel verschoben wird. Bestehende Projekte werden nie überschrieben.
- Der Projektindex wird atomar ersetzt. Ein lokaler Dateilock und eine Revisionsnummer verhindern, dass eine veraltete zweite Instanz neuere Befunde überschreibt.
- Projektdateien werden ausschließlich über validierte relative Pfade adressiert. Pfadtraversal und symbolische Links werden abgewiesen.
- Die APK wird beim Wiederöffnen und vor der Installation gegen ihren gespeicherten Hash geprüft. Befunddateien werden vor Vorschau und Export geprüft. Das ist eine Konsistenzprüfung, keine kryptografische Beglaubigung durch Dritte.
- Nicht referenzierte zusätzliche Dateien werden nicht exportiert. Bei einem Prozessabsturz vor dem Index-Commit können unreferenzierte Dateien übrig bleiben; sie werden nicht automatisch als Befund übernommen.
- Ein gespeicherter Startzeitpunkt ohne Sitzungsende kann auf einen abgebrochenen Lauf hinweisen. Wiederöffnen nimmt eine solche Sitzung nicht stillschweigend wieder auf.

## Statische Analyse

Lokale SDK-Werkzeuge: AAPT2 für Badging und Berechtigungen, `apkanalyzer manifest print` für das XML und `apkanalyzer dex packages --defined-only` für Klassen und Methoden. Benötigt werden die SDK Command-line Tools und eine funktionierende lokale Java-Laufzeit. Keine Netzwerk- oder Cloud-API. Das Manifest wird ohne DTDs oder externe Entity-Auflösung geparst.

Erfasst werden Paket, Version und SDK-Stufen, Application-Attribute, Activities und Aliase, Services, Receiver, Provider, explizite `exported`-/`enabled`-Werte, deklarierte bzw. vom Application-Element übernommene Komponentenberechtigungen sowie Intent-Aktionen, Kategorien und Data-Attribute. Nicht alle Android-Vererbungs- und Laufzeitregeln werden ausgewertet; entscheidend bleiben das vollständige XML und die deklarierte Abdeckung.

Schlägt das DEX-Inventar fehl, bleibt die Manifestanalyse verwendbar, und der Fehler wird als Einschränkung dokumentiert. Werkzeugausgaben sind auf 4 MiB begrenzt; ein abgeschnittenes DEX-Inventar ist markiert, und der Steckbrief sagt das dazu. Textvorschauen zeigen höchstens 200.000 Zeichen; die gespeicherten Dateien bleiben innerhalb der Werkzeuggrenze vollständig.

### Steckbrief

Bibliotheken werden an Manifest-Komponenten, nativen Bibliotheken (`lib/*/*.so`), Bibliothekskennungen (`*.properties`, `META-INF/*.version`) und, soweit vorhanden, am DEX-Inventar erkannt. Der Steckbrief zeigt, was eingebunden ist, nicht, ob oder wie es zur Laufzeit genutzt wird. Berechtigungen sind nach Themen gruppiert und mit Androids Einstufung gekennzeichnet: Freigabe nötig, Sonderzugriff, ohne Rückfrage, nur Systemapps, Hersteller oder App-intern.

REA/JADX-Dekompilierung, Referenzen, Frida-Java-Messpunkte und PCAP-Aufzeichnung oder -Import beschreibt [Code- und Datenflussanalyse](deep-analysis.md). Neue Befundtypen heben ein Projekt auf Schema 2; Schema-1-Projekte bleiben lesbar. JNI-/Native-Dekompilierung, automatische Vulnerability-Scans und vollständige Netzwerkabdeckung sind nicht enthalten.

Referenzen: [APK Analyzer CLI](https://developer.android.com/tools/apkanalyzer), [Überblick über das App-Manifest](https://developer.android.com/guide/topics/manifest/manifest-intro), [Intents und Intent-Filter](https://developer.android.com/guide/components/intents-filters).

## Reproduzierbare Prüfung

```sh
CLANG_MODULE_CACHE_PATH="$TMPDIR/android-analyxer-clang-cache" swift test --disable-sandbox
swift run --disable-sandbox android-analyxer-cli project-create \
  .local/fixture/android-analyxer-fixture.apk .local/my-analysis.androidlab
swift run --disable-sandbox android-analyxer-cli project-info .local/my-analysis.androidlab
# Nur auf einem ausdrücklich gewählten, entbehrlichen Testemulator:
swift run --disable-sandbox android-analyxer-cli project-smoke emulator-5580 \
  .local/fixture/android-analyxer-fixture.apk .local/new-project-test.androidlab
```

`project-smoke` akzeptiert ausschließlich das synthetische Fixture-Paket und eine Emulator-Seriennummer. Es prüft Installation, Start, Navigation, Logs, Screenshot, Notiz, Sitzungsende, Wiederöffnen und Export-Roundtrip über dieselben Core-APIs wie die Oberfläche.

## Import aus einem Google-Play-Gerät

**Installierte Apps → Untersuchen …** kopiert die von Android gemeldete APK-Liste vollständig, sichert sie mit SHA-256 und prüft, dass Paketpfade und Boot-ID unverändert sind. Paket und Version der Splits müssen zur Basis passen. Der Import enthält keine privaten App-Daten. Quelle, Android-Installerangabe und installierte Pfade bleiben im Schema-3-Projekt erhalten; die Installerangabe ist keine Aussage über Kaufrechte oder Store-Verfügbarkeit.

**Installierte App zuordnen** vergleicht danach alle installierten APK-Hashes mit dem Projekt und protokolliert eine Prüfung statt einer vorgetäuschten Installation. Nach dem Wiederöffnen eine neue Testsitzung beginnen und erneut zuordnen. **APKs installieren** installiert den gesamten Satz per `install-multiple`, beispielsweise auf einem geeigneten Analysegerät. Ein Store-Update oder ein nachgeladenes Feature kann den Abgleich ungültig machen: dann neu importieren.

Der statische Hauptbericht und die Komponentenübersicht beschreiben die Basis-APK. REA kann jede enthaltene APK separat untersuchen. Exporte enthalten sämtliche APKs und prüfen ihre Integrität. Schema 1 und 2 bleiben lesbar; zusätzliche REA-Befunde stufen Schema 3 nicht zurück.
