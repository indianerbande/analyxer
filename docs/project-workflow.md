# Analyseprojekte · Version 0.4

Ein Projekt verbindet genau eine App-Version (einzelne APK oder installierter Basis-/Split-Satz) mit statischen Befunden und beliebig vielen dokumentierten Testsitzungen. Die APK wird beim Anlegen kopiert. Die Analyse, spätere Installation und der Export verwenden diese Kopie. Das Original kann danach verschoben werden.

## Bedienung

1. **APK öffnen / Neues Projekt aus APK:** APK auswählen, neuen Projektordner festlegen. Der Ordner darf noch nicht existieren. Die Endung `.androidlab` ist eine Namenskonvention; es handelt sich um einen normalen Ordner.
2. **Statische Analyse:** Bericht, vollständiges Manifest und DEX-Inventar direkt in der App ansehen. Komponenten lassen sich nach Namen und Typ filtern. `exported` wird als expliziter Manifest-Wert gezeigt. Fehlende Werte werden nicht als `false` interpretiert.
3. **Testsitzung beginnen:** vollständig gestartetes Android-Gerät auswählen. Gerätekennung, AVD-Name (wenn verfügbar), Android-/SDK-Version, ABI, Modell, Build-Fingerprint, Boot-ID und ADB-Version werden gespeichert.
4. **APK installieren → Projekt-App starten:** Nur die Projekt-APK wird installiert und nur ihr Paket gestartet. Ein Start im Projektablauf benötigt eine bestätigte Installation derselben Sitzung.
5. **Beobachten:** Screenshot, App-Logcat und Navigation über den Projektbereich ausführen. Erfolgreiche Aktionen und Fehler werden sofort als getrennte Befunde gespeichert. Notizen mit „Notiz speichern“ sichern.
6. **Sitzung beenden / später fortsetzen:** Projekt erneut öffnen; alte Befunde bleiben sichtbar. Laufzeitaktionen benötigen eine neue ausdrücklich begonnene Sitzung. Ein Gerätetausch oder Android-Neustart bei gleicher ADB-Seriennummer wird über die Boot-ID erkannt.
7. **Gesamtexport:** neuen Zielordner wählen. Er enthält APK, Projektindex, alle referenzierten Befunddateien und `report.txt` mit statischem Bericht, Sitzungsdaten, Aktionen und Notizen. Der Export kann wieder als Projekt geöffnet werden.

Die allgemeinen Seiten Geräte, Installierte Apps und Logcat bleiben zusätzliche Einzelwerkzeuge. Automatische Projektaufzeichnung erfolgt über die Aktionen im Bereich **Analyseprojekte**. Screenshots zeigen den gesamten Gerätebildschirm. App-Logcat wird auf den aktuellen Hauptprozess gefiltert, erfasst keine Nebenprozesse und ist eine begrenzte Momentaufnahme. Ältere Einträge derselben PID können enthalten sein.

## Ablage und Integrität

```text
Beispiel.androidlab/
  project.json                 # Schema 1/2/3, Revision, APK-Identität, Analyse, Sitzungen, Befundindex
  input/split-1.apk            # optional: weitere APKs, jeweils mit SHA-256
  input/application.apk        # eigene APK-Kopie
  evidence/<UUID>.txt          # Berichte, DEX, Aktionen, Logs, Notizen, Fehler
  evidence/<UUID>.xml          # dekodiertes Manifest
  evidence/<UUID>.png          # Screenshots
  .write-lock                  # lokale Schreibkoordination; nicht im Export
  report.txt                   # zusätzlicher Gesamtbericht im Export
```

Zeitstempel werden in UTC/ISO-8601 gespeichert und in der Oberfläche lokal angezeigt. Jeder Befund ist an einen Zeitstempel, einen SHA-256 und optional eine Testsitzung gebunden. Statische Berichte sind nicht als Laufzeitbeobachtungen gekennzeichnet.

- Anlegen und Export geschehen in einem neuen temporären Nachbarordner; erst nach erfolgreichem Abschluss wird dieser an das Ziel verschoben. Bestehende Projekte werden nicht überschrieben.
- Der Projektindex wird atomar ersetzt. Ein lokaler Dateilock und eine Revision verhindern, dass eine veraltete zweite Instanz neue Befunde überschreibt.
- Projektdateien werden ausschließlich über validierte relative Pfade adressiert. Pfadtraversal und symbolische Links werden abgewiesen.
- Die APK wird beim Wiederöffnen und vor der Installation gegen ihren gespeicherten Hash geprüft. Befunddateien werden vor Vorschau und Export geprüft. Das ist eine Konsistenzprüfung, keine kryptografische Beglaubigung durch Dritte.
- Nicht referenzierte zusätzliche Dateien werden nicht exportiert. Bei einem Prozessabsturz vor dem Index-Commit können unreferenzierte Dateien übrig bleiben; sie werden nicht automatisch als Befund übernommen.
- Ein gespeicherter Zeitstempel ohne Sitzungsende kann auf einen abgebrochenen Lauf hinweisen. Wiederöffnen nimmt eine solche Sitzung nicht stillschweigend wieder auf.

## Statische Analyse

Lokale SDK-Werkzeuge: AAPT2 für Badging/Berechtigungen, `apkanalyzer manifest print` für XML sowie `apkanalyzer dex packages --defined-only` für Klassen/Methoden. Benötigt SDK Command-line Tools und eine funktionierende lokale Java-Laufzeit. Keine Netzwerk-/Cloud-API. Das Manifest wird ohne DTDs oder externe Entity-Auflösung geparst.

Erfasst werden Paket/Version/SDK, Application-Attribute, Activities und Aliase, Services, Receiver, Provider, explizite Export-/Enabled-Werte, deklarierte bzw. vom Application-Element übernommene Komponentenberechtigungen sowie Intent-Aktionen, Kategorien und Data-Attribute. Nicht alle Android-Vererbungs- und Laufzeitregeln werden ausgewertet. Entscheidend bleiben das vollständige XML und die deklarierte Abdeckung.

Ein fehlgeschlagenes DEX-Inventar lässt die Manifestanalyse verwendbar und wird als Einschränkung dokumentiert. Werkzeugausgaben sind auf 4 MiB begrenzt; abgeschnittenes DEX-Inventar ist entsprechend markiert. Textvorschauen zeigen höchstens 200.000 Zeichen, die gespeicherten Dateien bleiben vollständig innerhalb der Werkzeuggrenze.

Zusätzlich bietet v0.3 REA/JADX-Dekompilierung, Referenzen, gezielte Frida-Java-Messpunkte und PCAP-Aufzeichnung/-Import. Siehe [Code- und Datenflussanalyse](deep-analysis.md). Neue Befundtypen heben das Projekt auf Schema 2; vorhandene Schema-1-Projekte bleiben lesbar. JNI-/Native-Dekompilierung, automatische Vulnerability-Scans und vollständige Netzwerkabdeckung sind nicht enthalten.

Primärreferenzen: [APK Analyzer CLI](https://developer.android.com/tools/apkanalyzer), [Manifest-Elemente](https://developer.android.com/guide/topics/manifest/manifest-intro), [Intents und Filter](https://developer.android.com/guide/components/intents-filters).

## Reproduzierbare Prüfung

```sh
CLANG_MODULE_CACHE_PATH=/tmp/android-analyxer-clang-cache swift test --disable-sandbox
swift run --disable-sandbox android-analyxer-cli project-create \
  .local/fixture/android-analyxer-fixture.apk .local/meine-analyse.androidlab
swift run --disable-sandbox android-analyxer-cli project-info .local/meine-analyse.androidlab
# Nur auf dem ausdrücklich ausgewählten, entbehrlichen Testemulator:
swift run --disable-sandbox android-analyxer-cli project-smoke emulator-5580 \
  .local/fixture/android-analyxer-fixture.apk .local/neuer-projekt-test.androidlab
```

`project-smoke` akzeptiert ausschließlich das synthetische Fixture-Paket und eine Emulator-Seriennummer. Es prüft Installation, Start, Navigation, Logs, Screenshot, Notiz, Sitzungsende, Wiederöffnen und Export-Roundtrip über dieselben Core-APIs wie die Oberfläche.

## Import aus einem Google-Play-Gerät (v0.4)

Unter **Installierte Apps → Untersuchen** wird die von Android gemeldete APK-Liste vollständig kopiert, mit SHA-256 gesichert und auf unveränderte Paketpfade und Boot-ID geprüft. Paket und Version der Splits müssen zur Basis passen. Der Import enthält keine privaten App-Daten. Quelle, Android-Installerangabe und installierte Pfade bleiben im Schema-3-Projekt erhalten; die Installerangabe ist keine Aussage über Kaufrechte oder Store-Verfügbarkeit.

Die anschließende Aktion **Installierte App zuordnen** vergleicht alle installierten APK-Hashes mit dem Projekt und protokolliert eine Prüfung statt einer vorgetäuschten Installation. Nach Wiederöffnung eine neue Testsitzung beginnen und erneut zuordnen. **APKs installieren** installiert den gesamten Satz per `install-multiple`, beispielsweise auf einem geeigneten Analysegerät. Ein Store-Update oder nachgeladenes Feature kann den Abgleich ungültig machen: dann neu importieren.

Der statische Hauptbericht und die Komponentenübersicht beschreiben die Basis-APK. REA kann jede enthaltene APK separat untersuchen. Exporte enthalten sämtliche APKs und prüfen ihre Integrität. Schema 1 und 2 bleiben lesbar; zusätzliche REA-Befunde stufen Schema 3 nicht zurück.
