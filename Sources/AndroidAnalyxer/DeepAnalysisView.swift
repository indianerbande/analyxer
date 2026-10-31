import SwiftUI
import AndroidAnalyxerCore

struct DeepAnalysisView: View {
    @EnvironmentObject var model: AnalyxerModel
    @State private var className = ""
    @State private var methodName = ""
    @State private var search = ""
    @State private var overload = ""
    @State private var argumentTypes = "java.lang.String"
    @State private var duration = 15
    private var selectedOverload: Int? { Int(overload) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("2 · Code und Datenflüsse untersuchen").font(.headline)
            DisclosureGroup("Lokale Analysewerkzeuge") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("REA führt APK-Analyse mit JADX und Prozessbeobachtung mit Frida aus. Ein Werkzeugprofil enthält die lokalen Programmpfade.").font(.caption).foregroundStyle(.secondary)
                    TextField("REA-Programm oder Node (absoluter Pfad)", text: $model.analysisTools.executable)
                    TextField("REA-CLI-Skript (bei Node)", text: $model.analysisTools.cliScript)
                    TextField("JADX-MCP JAR", text: $model.analysisTools.jadxJAR)
                    TextField("JAVA_HOME", text: $model.analysisTools.javaHome)
                    TextField("Kompilierte Frida-Java-Bridge", text: $model.analysisTools.javaBridge)
                    HStack {
                        Button("Werkzeugprofil laden …") { model.loadAnalysisTools() }
                        Button("Pfade speichern") { model.saveAnalysisTools() }
                    }
                }.textFieldStyle(.roundedBorder).padding(.top, 10)
            }
            if let project = model.project, project.apkFiles.count > 1 {
                Picker("APK für REA", selection: $model.analysisComponent) {
                    ForEach(project.apkFiles) { file in Text(file.name).tag(file.relativePath) }
                }
                Text("Die Analyse gilt jeweils für die gewählte APK. Dynamisch später geladene Features müssen erneut importiert werden.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("APK mit REA untersuchen") { model.analyzeWithREA(.package) }
                TextField("Klassenname enthält …", text: $search).textFieldStyle(.roundedBorder)
                Button("Klassen suchen") { model.analyzeWithREA(.classes(search)) }
            }
            TextField("Vollständiger Klassenname", text: $className).textFieldStyle(.roundedBorder)
            HStack {
                Button("Methoden auflisten") { model.analyzeWithREA(.members(className)) }.disabled(className.isEmpty)
                TextField("Methodenname", text: $methodName).textFieldStyle(.roundedBorder)
                TextField("Überladung", text: $overload).textFieldStyle(.roundedBorder).frame(width: 110)
                Button("Dekompilieren") { model.analyzeWithREA(.method(className: className, methodName: methodName, overload: selectedOverload)) }
                    .disabled(className.isEmpty || methodName.isEmpty || (!overload.isEmpty && selectedOverload == nil))
                Button("Referenzen") { model.analyzeWithREA(.references(className: className, methodName: methodName.isEmpty ? nil : methodName, overload: selectedOverload)) }
                    .disabled(className.isEmpty || (!overload.isEmpty && selectedOverload == nil))
            }
            Divider()
            Text("Daten im App-Prozess").font(.subheadline.weight(.semibold))
            Text("Beobachtet Eingaben, Rückgaben und Fehler der oben gewählten Methode. Für Klartextdaten eine Stelle vor dem Versand oder nach der Entschlüsselung wählen. Während der Aufnahme die App im Android-Fenster bedienen.").font(.caption).foregroundStyle(.secondary)
            TextField("Exakte Java-Argumenttypen, durch Komma getrennt; leer = keine Argumente", text: $argumentTypes).textFieldStyle(.roundedBorder)
            HStack {
                Stepper("\(duration) Sekunden", value: $duration, in: 3...60, step: 3)
                Spacer()
                Button("Methode beobachten") {
                    model.observeMethod(className: className, methodName: methodName, argumentTypes: argumentTypes, seconds: duration)
                }.disabled(!model.projectSessionSelected || !model.projectInstalled || className.isEmpty || methodName.isEmpty)
            }
            Text("Benötigt einen erreichbaren Frida-Server auf dem Analysegerät. Google-Play-Geräte unterstützen diesen Zugang ohne zusätzliche Vorbereitung nicht. Die Aufnahme ist auf die Projekt-App und die gewählte Methode begrenzt; leere Ergebnisse belegen keinen fehlenden Datenverkehr.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Netzwerkaufzeichnung").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Mobilfunk/WAN aufnehmen") { model.captureProjectNetwork(seconds: duration) }.disabled(!model.projectSessionSelected)
                Button("PCAP importieren …") { model.importProjectCapture() }.disabled(model.activeSessionID == nil)
            }
            Text("Die Emulator-Konsole erfasst nur den alten Mobilfunk/WAN-Pfad und ersetzt einen dort laufenden Konsolenmitschnitt. Modernes Emulator-WLAN ist nicht enthalten. Für andere Aufnahmen eine PCAP-Datei importieren. Geräteverkehr umfasst auch Android und Google-Dienste; verschlüsselte Nutzdaten bleiben verschlüsselt.").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.busy)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
