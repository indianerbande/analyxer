import SwiftUI
import AnalyxerCore

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
            Text("2 · Examine Code and Data Flows").font(.headline)
            DisclosureGroup("Local Analysis Tools") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("REA runs APK analysis with JADX and process observation with Frida. A tool profile holds the local program paths.").font(.caption).foregroundStyle(.secondary)
                    TextField("REA program or Node (absolute path)", text: $model.analysisTools.executable)
                    TextField("REA CLI script (with Node)", text: $model.analysisTools.cliScript)
                    TextField("JADX MCP JAR", text: $model.analysisTools.jadxJAR)
                    TextField("JAVA_HOME", text: $model.analysisTools.javaHome)
                    TextField("Compiled Frida Java bridge", text: $model.analysisTools.javaBridge)
                    HStack {
                        Button("Load Tool Profile …") { model.loadAnalysisTools() }
                        Button("Save Paths") { model.saveAnalysisTools() }
                    }
                }.textFieldStyle(.roundedBorder).padding(.top, 10)
            }
            if let project = model.project, project.apkFiles.count > 1 {
                Picker("APK for REA", selection: $model.analysisComponent) {
                    ForEach(project.apkFiles) { file in Text(file.name).tag(file.relativePath) }
                }
                Text("The analysis applies to the selected APK. Features loaded dynamically later must be imported again.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Inspect APK with REA") { model.analyzeWithREA(.package) }
                TextField("Class name contains …", text: $search).textFieldStyle(.roundedBorder)
                Button("Find Classes") { model.analyzeWithREA(.classes(search)) }
            }
            TextField("Full class name", text: $className).textFieldStyle(.roundedBorder)
            HStack {
                Button("List Methods") { model.analyzeWithREA(.members(className)) }.disabled(className.isEmpty)
                TextField("Method name", text: $methodName).textFieldStyle(.roundedBorder)
                TextField("Overload", text: $overload).textFieldStyle(.roundedBorder).frame(width: 110)
                Button("Decompile") { model.analyzeWithREA(.method(className: className, methodName: methodName, overload: selectedOverload)) }
                    .disabled(className.isEmpty || methodName.isEmpty || (!overload.isEmpty && selectedOverload == nil))
                Button("References") { model.analyzeWithREA(.references(className: className, methodName: methodName.isEmpty ? nil : methodName, overload: selectedOverload)) }
                    .disabled(className.isEmpty || (!overload.isEmpty && selectedOverload == nil))
            }
            Divider()
            Text("Data in the App Process").font(.subheadline.weight(.semibold))
            Text("Observes inputs, return values and errors of the method chosen above. For plaintext data, choose a point before sending or after decryption. Use the app in the Android window while recording.").font(.caption).foregroundStyle(.secondary)
            TextField("Exact Java argument types, comma-separated; empty = no arguments", text: $argumentTypes).textFieldStyle(.roundedBorder)
            HStack {
                Stepper("\(duration) seconds", value: $duration, in: 3...60, step: 3)
                Spacer()
                Button("Observe Method") {
                    model.observeMethod(className: className, methodName: methodName, argumentTypes: argumentTypes, seconds: duration)
                }.disabled(!model.projectSessionSelected || !model.projectInstalled || className.isEmpty || methodName.isEmpty)
            }
            Text("Needs a reachable Frida server on the analysis device. Google Play devices do not support this access without extra preparation. Recording is limited to the project app and the chosen method; empty results do not prove that there is no data traffic.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Network Capture").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Record Mobile/WAN") { model.captureProjectNetwork(seconds: duration) }.disabled(!model.projectSessionSelected)
                Button("Import PCAP …") { model.importProjectCapture() }.disabled(model.activeSessionID == nil)
            }
            Text("The emulator console captures only the old mobile/WAN path and replaces a console capture already running there. Modern emulator Wi-Fi is not included. For other captures, import a PCAP file. Device traffic also includes Android and Google services; encrypted payloads stay encrypted.").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.busy)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
