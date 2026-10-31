# Code- und Datenflussanalyse

[English](../deep-analysis.md)

## Konzept

Eine APK wird unverändert als Projektquelle aufbewahrt. REA/JADX untersucht diese Quelle und liefert Klassen, Methoden, dekompilierten Code und eingehende statische Referenzen. Daraus wählst du konkrete Messpunkte für die laufende App: etwa eine Methode, die einen Request erzeugt, oder eine, die eine bereits entschlüsselte Antwort verarbeitet.

Die Laufzeitbeobachtung erfolgt über REA/Frida. Sie erfasst Argumente, Rückgaben und Ausnahme-Typen ausgewählter Methoden. Die Originalmethode wird weiter ausgeführt; Rückgaben und Exceptions werden weitergereicht. Instrumentierung kann dennoch Timing und Laufzeitverhalten beeinflussen. Netzwerkmitschnitte ergänzen die Prozessbeobachtung um sichtbare Gegenstellen, Ports und Paketmengen; sie entschlüsseln keine TLS-Nutzdaten. Codefunde, Prozessereignisse und Netzverkehr sind verschiedene Belegarten, keine automatisch bewiesene Kausalkette.

Im Projekt ist das der Abschnitt **2 · Code und Datenflüsse untersuchen**. Alle Ergebnisse werden im Analyseprojekt gespeichert, zusammen mit APK-Hash, Sitzung, Zeitstempeln, Gerätemetadaten, den unveränderten REA-Evidence-Dateien und dem tatsächlich verwendeten Beobachtungsskript.

## Lokale Werkzeuge

Getestet mit REA 6.5.0, Node 24.15.0, JADX headless MCP 0.7.1, einem vollständigen JDK 25, Frida 17.23.2 und frida-java-bridge 7.0.13; die Werkzeugverwaltung installiert REA 6.8.0 und Node 24.22.2. Die JVM ist standardmäßig auf 1 GiB begrenzt. **Einrichtung → Analysewerkzeuge** prüft und installiert diese Werkzeuge und setzt das Werkzeugprofil; siehe [Einrichtung und Werkzeuge](setup.md). **Werkzeugprofil laden …** im Projektbereich nimmt stattdessen ein JSON-Profil an.

Die JADX-JAR stammt aus dem offiziellen Release, auf das REA verweist (SHA-256 für 0.7.1: `6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75`). `scripts/instrumentation/build-java-bridge.mjs` baut die Java-Bridge aus einer ausdrücklich gewählten lokalen Installation von frida-java-bridge mit Fridas Compiler; die Werkzeugverwaltung tut dasselbe automatisch.

## APK untersuchen

1. Projekt öffnen; das Werkzeugprofil muss bereit sein.
2. **APK mit REA untersuchen** für Paket- und Manifestbefunde oder **Klassen suchen** verwenden.
3. Vollständigen Klassennamen übernehmen und **Methoden auflisten** wählen.
4. Methodennamen und gegebenenfalls den Überladungsindex aus der Liste eintragen; **Dekompilieren** oder **Referenzen** wählen. Überladungsindizes sind nullbasiert.

REA analysiert immer die geprüfte Projektkopie. Die Antwort muss zur Operation und zum SHA-256 der APK passen. Werkzeugfehler werden als Fehlerbefunde gespeichert. Die Vorschau stellt den normalisierten Befund lesbar dar; die Original-JSON mit Evidence-ID, Provider und Grenzen bleibt erhalten. Die Analyse führt die APK nie aus. Eingehende statische Referenzen beweisen nicht, dass ein Aufruf zur Laufzeit stattfindet.

## Daten im Prozess beobachten

Voraussetzung ist ein vorbereitetes Analysegerät mit passendem laufendem frida-server auf Gast-Port 27042. Die Identitätsprüfung benötigt außerdem lesbare `/proc/<PID>/cmdline` und `/proc/<PID>/stat`; im geprüften Google-APIs-Image läuft dafür adbd mit Root-Rechten. Ein Root-frida-server allein garantiert diese ADB-Leserechte nicht. Die App aktiviert Root nicht, startet frida-server nicht und verändert keine Zertifikate. Reguläre Google-Play-Images sind ohne zusätzliche Vorbereitung nicht geeignet; ihre normale Verwendung ist ein eigener Gerätemodus.

1. Testsitzung beginnen, Projekt-APK installieren und starten.
2. Klasse und Methode aus der Codeanalyse eintragen.
3. Exakte Java-Argumenttypen eintragen, durch Komma getrennt, beispielsweise `java.lang.String` oder `[B`; leer bedeutet keine Parameter. Der statische Überladungsindex wird hier nicht verwendet: Entscheidend ist die tatsächliche Java-Typenliste.
4. Dauer wählen und **Methode beobachten** drücken. Während der Aufnahme die App im Android-Fenster bedienen.
5. Prozessbefund und Aufnahmekontext in der Befundliste öffnen.

Vor der Aufnahme werden die installierten APKs per ADB übertragen und gegen den vollständigen APK-Satz des Projekts geprüft. Importierte Basis-/Split-Sätze werden unterstützt; eine einzelne Basis-APK kann eine Split-Installation nicht belegen. Statische REA-Abfragen beziehen sich auf die im Auswahlfeld gewählte APK. Das Ziel ist der eindeutige App-Hauptprozess. Boot-ID, Prozessname und Prozess-Startzeit binden die Aufnahme; Gerätewechsel, Neustart oder PID-Wiederverwendung führen zu einem Fehler. Die dynamische ADB-Portweiterleitung wird nach der Aufnahme entfernt; Frida wird abgehängt, die App läuft weiter.

Die Oberfläche bietet einen Messpunkt pro Aufnahme; die Core-API unterstützt bis zu acht. Erfasst werden primitive Werte, Strings und Bytearrays; sonstige Objekte bleiben opak. Es werden keine Streams gelesen und keine beliebigen Objektmethoden zur Darstellung aufgerufen. Standard: 200 Aufrufe und 4.096 Zeichen je Wert, höchstens 60 Sekunden. Grenzen und abgeschnittene Werte werden markiert. Bereits laufende oder vor Installation des Hooks abgeschlossene Aufrufe fehlen. Kein beobachteter Aufruf bedeutet nur, dass im Aufnahmefenster kein passender Aufruf registriert wurde.

Es handelt sich um gezielte Java-Beobachtung, nicht um automatische Erfassung sämtlicher HTTP-Bibliotheken, JNI-/Native-Funktionen oder Nebenprozesse. Reflexion, dynamische Klassenloader, native TLS-Stacks und zusätzliche Inhaltsverschlüsselung können andere Messpunkte oder weitere Adapter erfordern. Zertifikat-Pinning wird nicht verändert.

## Netzwerkmitschnitt

**Mobilfunk/WAN aufnehmen** nutzt die Konsole des SDK-Emulators. Bei Emulator 37.1.11 erfasst sie den Legacy-WAN/Cellular-Pfad, nicht das moderne netsim-WLAN. Sie ersetzt einen bereits laufenden Konsolenmitschnitt. Die App ändert keine Gastnetzwerkeinstellungen. Die Aufnahme dauert höchstens 60 Sekunden; bis zu 32 MiB werden übernommen. Bei Überschreitung wird die Aufnahme gestoppt und verworfen.

**PCAP importieren …** nimmt externe klassische PCAP-Dateien bis 32 MiB auf. Herkunft, Aufnahmegerät und Zuordnung zur aktiven Sitzung bleiben ausdrücklich unbestätigt. PCAPNG wird nicht unterstützt. Der eingebaute Parser zeigt Paketanzahl, sichtbare IPv4-/IPv6-Endpunkte und TCP-/UDP-Ports. Er unterstützt Ethernet/VLAN, Linux cooked v1/v2 und rohe IP-Pakete; fragmentierte Pakete und IPv6-Erweiterungsheader werden nur teilweise ausgewertet. Er rekonstruiert keine TCP-Streams, DNS-Namen, HTTP-Bodies oder TLS-Klartexte.

Geräteverkehr kann Android, Google-Dienste und andere Apps enthalten. Zeitliche Nähe zu einer Bedienaktion beweist nicht, welche App ihn verursacht hat. Der vollständige PCAP wird mit Hash exportiert und kann in einem geeigneten externen Werkzeug weiter untersucht werden. REAs Linux/Windows-PCAP-Provider wird auf macOS nicht vorausgesetzt.

## Reproduzierbarer lokaler HTTPS-Test

`scripts/build-fixture.sh` erzeugt die synthetische APK und ein lokales Testzertifikat mit IP-SAN `10.0.2.2`. Der private Testschlüssel bleibt unter `.local/tls`. Die Fixture vertraut ausschließlich diesem Zertifikat für ihren festen lokalen Testendpunkt; die Hostname-Prüfung bleibt aktiv. Ein normaler Start löst keine Netzwerkaufrufe aus. Nur das explizite Intent-Extra `run_tls=true` startet acht synthetische HTTPS-Austausche.

```sh
scripts/build-fixture.sh
python3 scripts/fixture-tls-server.py
# In einem zweiten Terminal, mit vorbereitetem, isoliertem Testemulator:
swift run --disable-sandbox android-analyxer-cli analysis-smoke emulator-5580 \
  .local/fixture/android-analyxer-fixture.apk .local/new-analysis-test.androidlab \
  .local/analysis-tools.json
```

Der Server bindet ausschließlich `127.0.0.1:18443`. Der Test akzeptiert nur das Fixture-Paket. Er dekompiliert `buildRequest(String)`, installiert die geprüfte APK und beobachtet `buildRequest` und `consumeResponse` während echter lokaler TLS-Kommunikation. Anschließend prüft er Klartextmarker und den Export-Roundtrip. Kein externer Dienst und keine privaten APKs werden benötigt.

Referenzen: [REA](https://github.com/morluto/rea), [Frida auf Android](https://frida.re/docs/android/), [Frida JavaScript API](https://frida.re/docs/javascript-api/), [Android Emulator console](https://developer.android.com/studio/run/emulator-console), [Advanced emulator networking](https://developer.android.com/studio/run/emulator-networking-advanced).
