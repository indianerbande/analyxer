# Code- und Datenflussanalyse · v0.3

## Konzept

Eine APK wird unverändert als Projektquelle aufbewahrt. REA/JADX untersucht diese Quelle und liefert Klassen, Methoden, dekompilierten Code und eingehende statische Referenzen. Daraus wählt der Benutzer konkrete Messpunkte für die laufende App: etwa eine Methode, die einen Request erzeugt, oder eine Methode, die eine bereits entschlüsselte Antwort verarbeitet.

Die Laufzeitbeobachtung erfolgt über REA/Frida. Sie erfasst ausgewählte Methodenargumente, Rückgaben und Ausnahme-Typen. Die Originalmethode wird weiter ausgeführt, Rückgaben und Exceptions werden weitergereicht. Instrumentierung kann dennoch Timing und Laufzeitverhalten beeinflussen. Netzwerk-PCAPs ergänzen die Prozessbeobachtung um sichtbare Gegenstellen, Ports und Paketmengen; sie entschlüsseln keine TLS-Nutzdaten. Codefunde, Prozessereignisse und Netzverkehr sind verschiedene Belegarten, keine automatisch bewiesene Kausalkette.

Die Bedienoberfläche enthält den Abschnitt **Code und Datenflüsse untersuchen**. Alle Ergebnisse liegen im bestehenden Analyseprojekt, zusammen mit APK-Hash, Sitzung, Zeitstempeln, Gerätemetadaten, unveränderten REA-Evidence-Dateien und dem tatsächlich verwendeten Beobachtungsskript.

## Lokale Werkzeuge

Getestet: REA 6.5.0, Node 24.15.0, JADX headless MCP 0.7.1, vollständiges JDK 25, Frida 17.23.2 und frida-java-bridge 7.0.13. Die JVM ist standardmäßig auf 1 GiB begrenzt. Werkzeuge werden als explizite Dateipfade ausgewählt; die App installiert oder lädt keine Provider automatisch.

Ein Werkzeugprofil ist eine kleine JSON-Datei, z. B. `.local/analysis-tools.json` (nicht versioniert). In der App **Lokale Analysewerkzeuge → Werkzeugprofil laden** wählen. Das Profil enthält nur Programmpfade, keine Zugangsdaten. Schema:

```json
{
  "executable": "/absoluter/pfad/node",
  "cliScript": "/absoluter/pfad/rea-agents/scripts/rea.mjs",
  "jadxJAR": "/absoluter/pfad/jadx-headless-mcp-0.7.1-all.jar",
  "javaHome": "/absoluter/pfad/jdk/Contents/Home",
  "javaBridge": "/absoluter/pfad/java-bridge.bundle.js"
}
```

Ein eigenständiges REA-Programm kann ohne `cliScript` verwendet werden. Leere optionale Pfade werden als leere Strings gespeichert. Die JADX-JAR wurde aus dem offiziellen, von REA referenzierten Release bezogen; SHA-256 `6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75`. Alle lokalen Abhängigkeiten liegen außerhalb der verteilten App. Für die Bridge gibt es `scripts/instrumentation/build-java-bridge.mjs`; es kompiliert eine ausdrücklich gewählte lokale Installation von frida-java-bridge mit Fridas Compiler.

## APK untersuchen

1. Projekt öffnen und Werkzeugprofil auswählen.
2. **APK mit REA untersuchen** für Paket-/Manifestbefunde oder **Klassen suchen** verwenden.
3. Vollständigen Klassennamen übernehmen, **Methoden auflisten** wählen.
4. Methodennamen und gegebenenfalls den zurückgegebenen Überladungsindex eintragen; **Dekompilieren** oder **Referenzen** wählen. Überladungsindizes sind nullbasiert.

REA analysiert immer die geprüfte Projektkopie. Die Antwort muss zu Operation und APK-SHA passen. Werkzeugfehler werden als Fehlerbefunde gespeichert. Die Vorschau stellt den normalisierten Befund lesbar dar; die Original-JSON mit Evidence-ID, Provider und Grenzen bleibt erhalten. Die Analyse führt die APK nicht aus. Eingehende statische Referenzen beweisen keine tatsächlichen Laufzeitaufrufe.

## Daten im Prozess beobachten

Voraussetzung ist ein vorbereitetes Analysegerät mit passendem laufendem Frida-Server auf Gast-Port 27042. Die Identitätsprüfung benötigt außerdem lesbare `/proc/<PID>/cmdline` und `/proc/<PID>/stat`; im geprüften Google-APIs-Testimage läuft dafür adbd mit Root-Rechten. Ein Root-Frida-Server allein garantiert diese ADB-Leserechte nicht. Die App aktiviert Root nicht selbst, startet keinen Server und verändert keine Zertifikate. Reguläre Google-Play-Images sind hierfür ohne zusätzliche Vorbereitung nicht geeignet; ihre normale Verwendung bleibt ein eigener Gerätemodus.

1. Testsitzung beginnen, Projekt-APK installieren und starten.
2. Die konkrete Klasse und Methode aus der Codeanalyse eintragen.
3. Exakte Java-Argumenttypen eintragen, durch Komma getrennt, beispielsweise `java.lang.String` oder `[B`; leer bedeutet keine Parameter. Die statische Überladungsnummer wird hier nicht verwendet: Entscheidend ist die tatsächliche Java-Typenliste.
4. Dauer wählen und **Methode beobachten** drücken. Während der Aufnahme die App im Android-Fenster bedienen.
5. Prozessbefund und Aufnahmekontext in der Befundliste öffnen.

Vor der Aufnahme werden installierte APKs per ADB übertragen und gegen den vollständigen APK-Satz des Projekts geprüft. V0.4 unterstützt importierte Basis-/Split-Sätze; eine einzelne Basis-APK kann eine Split-Installation nicht belegen. Statische REA-Abfragen beziehen sich jeweils auf die im Auswahlfeld gewählte APK. Das Ziel ist der eindeutige App-Hauptprozess. Boot-ID, Prozessname und Prozess-Startzeit binden die Aufnahme; Gerätewechsel, Neustart oder PID-Wiederverwendung führen zu einem Fehler. Die eigene dynamische ADB-Portweiterleitung wird nach der Aufnahme entfernt; Frida wird abgehängt, die App läuft weiter.

Die Oberfläche bietet einen Messpunkt pro Aufnahme; die Core-API unterstützt bis zu acht. Erfasst werden primitive Werte, Strings und Bytearrays; sonstige Objekte bleiben opak. Es werden keine Streams gelesen und keine beliebigen Objektmethoden zur Darstellung aufgerufen. Standard: 200 Aufrufe und 4096 Zeichen je Wert, maximal 60 Sekunden. Grenzen und abgeschnittene Werte werden markiert. Bereits laufende oder vor Installation des Hooks abgeschlossene Aufrufe fehlen. Kein beobachteter Aufruf bedeutet nur, dass im Aufnahmefenster kein passender Aufruf registriert wurde.

Es handelt sich um gezielte Java-Beobachtung, nicht um automatische Erfassung sämtlicher HTTP-Bibliotheken, JNI-/Native-Funktionen oder Nebenprozesse. Reflexion, dynamische Klassenloader, native TLS-Stacks und zusätzliche Inhaltsverschlüsselung können andere Messpunkte oder weitere Adapter erfordern. Zertifikat-Pinning wird nicht verändert.

## Netzwerkaufzeichnung

**Mobilfunk/WAN aufnehmen** nutzt die SDK-Konsole. Bei Emulator 37.1.11 erfasst sie den Legacy-WAN/Cellular-Pfad, nicht das moderne netsim-WLAN. Sie ersetzt einen bereits laufenden Konsolenmitschnitt. Die App ändert keine Gastnetzwerkeinstellungen. Aufnahme maximal 60 Sekunden; bis zu 32 MiB werden übernommen. Bei Überschreitung wird die Aufnahme gestoppt und verworfen.

**PCAP importieren** nimmt externe klassische PCAP-Dateien bis 32 MiB auf. Herkunft, Aufnahmegerät und Zuordnung zur aktiven Sitzung bleiben ausdrücklich unbestätigt. PCAPNG ist nicht unterstützt. Der lokale Parser zeigt Paketanzahl, sichtbare IPv4-/IPv6-Endpunkte und TCP-/UDP-Ports. Er unterstützt Ethernet/VLAN, Linux cooked v1/v2 und rohe IP-Pakete; fragmentierte Pakete und IPv6-Erweiterungsheader haben begrenzte Auswertung. Er rekonstruiert keine TCP-Streams, DNS-Namen, HTTP-Bodies oder TLS-Klartexte.

Geräteverkehr kann Android, Google-Dienste und andere Apps enthalten. Zeitliche Nähe zur Bedienaktion beweist keine App-Zuordnung. Der vollständige PCAP wird mit Hash exportiert und kann in einem geeigneten externen Werkzeug weiter untersucht werden. REAs Linux/Windows-PCAP-Provider wird auf macOS nicht stillschweigend vorausgesetzt.

## Reproduzierbarer lokaler HTTPS-Nachweis

`scripts/build-fixture.sh` erzeugt die synthetische APK und ein lokales Testzertifikat mit IP-SAN `10.0.2.2`. Der private Testschlüssel liegt nur unter `.local/tls`. Die Fixture vertraut ausschließlich diesem Zertifikat für ihren festen lokalen Testendpunkt; Hostname-Prüfung bleibt aktiv. Normaler Start löst keine Netzwerkaufrufe aus. Nur das explizite Intent-Extra `run_tls=true` startet acht synthetische HTTPS-Austausche.

```sh
scripts/build-fixture.sh
python3 scripts/fixture-tls-server.py
# In einem zweiten Terminal, mit vorbereitetem isolierten Testemulator:
swift run --disable-sandbox android-analyxer-cli analysis-smoke emulator-5580 \
  .local/fixture/android-analyxer-fixture.apk .local/neuer-analysetest.androidlab \
  .local/analysis-tools.json
```

Der Server bindet ausschließlich `127.0.0.1:18443`. Der Test akzeptiert nur das Fixture-Paket. Er dekompiliert `buildRequest(String)`, installiert die geprüfte APK und beobachtet `buildRequest` und `consumeResponse` während echter lokaler TLS-Kommunikation. Anschließend prüft er Klartextmarker und den Export-Roundtrip. Kein externer Dienst und keine privaten APKs werden benötigt.

Primärreferenzen: [REA](https://github.com/morluto/rea), [Frida Android](https://frida.re/docs/android/), [Frida JavaScript API](https://frida.re/docs/javascript-api/), [Android Emulator console](https://developer.android.com/studio/run/emulator-console), [Advanced networking](https://developer.android.com/studio/run/emulator-networking-advanced).
