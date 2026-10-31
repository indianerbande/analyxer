import Foundation

/// One exact overload, chosen from static analysis. No wildcard interception.
public struct JavaMethodProbe: Codable, Equatable, Sendable {
    public let className: String
    public let methodName: String
    public let argumentTypes: [String]
    public init(className: String, methodName: String, argumentTypes: [String]) {
        self.className = className; self.methodName = methodName; self.argumentTypes = argumentTypes
    }
}

public struct InstrumentationRequest: Codable, Sendable {
    public let probes: [JavaMethodProbe]
    public let durationMilliseconds: Int
    public let maxEvents: Int
    public let maxValueCharacters: Int
    public init(probes: [JavaMethodProbe], durationMilliseconds: Int = 15_000,
                maxEvents: Int = 200, maxValueCharacters: Int = 4096) {
        self.probes = probes; self.durationMilliseconds = durationMilliseconds
        self.maxEvents = maxEvents; self.maxValueCharacters = maxValueCharacters
    }
    public func validate() throws {
        guard (1...8).contains(probes.count), (1000...60_000).contains(durationMilliseconds),
              (1...1000).contains(maxEvents), (32...16_384).contains(maxValueCharacters) else {
            throw AndroidAnalyxerError.invalidInput("1–8 Messpunkte, 1–60 Sekunden, 1–1000 Aufrufe und 32–16384 Zeichen je Wert sind erlaubt.")
        }
        var seen = Set<String>()
        for probe in probes {
            guard probe.className.count <= 512, probe.methodName.count <= 256,
                  probe.className.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)+$"#, options: .regularExpression) != nil,
                  probe.methodName.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil,
                  probe.argumentTypes.count <= 16, probe.argumentTypes.allSatisfy({ type in
                      type.count <= 512 && type.range(of: #"^(?:\[*(?:[ZBCSIJFD]|L[A-Za-z_$][A-Za-z0-9_.$]*;)|[A-Za-z_$][A-Za-z0-9_.$]*(?:\[\])*)$"#, options: .regularExpression) != nil
                  }) else {
                throw AndroidAnalyxerError.invalidInput("Messpunkte benötigen eine exakte Java-Klasse, Methode und Parameterliste.")
            }
            let key = probe.className + "#" + probe.methodName + "(" + probe.argumentTypes.joined(separator: ",") + ")"
            guard seen.insert(key).inserted else { throw AndroidAnalyxerError.invalidInput("Doppelter Messpunkt: \(key)") }
        }
    }
}

public struct InstrumentationCapture: Sendable {
    public let evidenceJSON: Data
    public let script: Data
    public let request: InstrumentationRequest
    public let serial: String
    public let packageName: String
    public let pid: Int
    public let observedAt: Date
    public let installedProbeCount: Int
    public let invocationCount: Int
    public let warnings: [String]
    public let summary: String
}

public struct InstrumentationError: LocalizedError, Sendable {
    public let message: String
    public let evidenceJSON: Data?
    public let script: Data?
    public var errorDescription: String? { message }
    public init(message: String, evidenceJSON: Data? = nil, script: Data? = nil) {
        self.message = message; self.evidenceJSON = evidenceJSON; self.script = script
    }
}

/// Runs an observation through REA's ephemeral Frida CLI, tied to one ADB device,
/// boot and main-process PID. Owns only its temporary forward and script directory.
/// A compatible Frida server must already be available on this selected device;
/// this service never roots devices, installs servers or changes certificate trust.
public struct InstrumentationService: Sendable {
    public let rea: REAConfiguration
    public let bridgeURL: URL
    private let runner: any CommandRunning
    public init(rea: REAConfiguration, bridgeURL: URL, runner: any CommandRunning = ProcessCommandRunner()) {
        self.rea = rea; self.bridgeURL = bridgeURL; self.runner = runner
    }

    public func capture(service: EmulatorService, serial: String, package: String,
                        expectedBootID: String, request: InstrumentationRequest) async throws -> InstrumentationCapture {
        try request.validate()
        guard package.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else {
            throw AndroidAnalyxerError.invalidInput("Ungültiges Android-Paket.")
        }
        guard try await service.bootIdentity(serial: serial) == expectedBootID else {
            throw AndroidAnalyxerError.failed("Android-Bootidentität geändert. Eine neue Testsitzung beginnen.")
        }
        let pidText = try await service.adb(serial: serial, arguments: ["shell", "pidof", package]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(pidText), pid > 0 else {
            throw AndroidAnalyxerError.failed("Kein eindeutiger Hauptprozess für \(package). Projekt-App zuerst starten.")
        }
        let initialIdentity = try await processIdentity(service: service, serial: serial, package: package, pid: pid)
        let script = try Self.script(request: request, bridge: Self.readBridge(bridgeURL), package: package, pid: pid)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("android-analyxer-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("probe.js")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let portText = try await service.adb(serial: serial, arguments: ["forward", "tcp:0", "tcp:27042"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw InstrumentationError(message: "ADB lieferte keinen eindeutigen lokalen Frida-Port.", script: Data(script.utf8))
        }
        var output: Data?
        let started = Date()
        do {
            let command = try rea.command(arguments: ["instrument-with-frida", "attach", String(pid),
                "--remote-address", "127.0.0.1:\(port)", "--script-file", scriptURL.path,
                "--duration-ms", String(request.durationMilliseconds), "--json"],
                timeout: Double(request.durationMilliseconds) / 1000 + 30, outputLimit: 24 * 1024 * 1024)
            let result = try await runner.run(command)
            output = result.stdout
            guard !result.truncated else { throw InstrumentationError(message: "REA-Ausgabe überschreitet 24 MiB; Aufnahme ist unvollständig.", evidenceJSON: result.stdout, script: Data(script.utf8)) }
            guard result.status == 0 else {
                throw InstrumentationError(message: "REA/Frida fehlgeschlagen: \(String(decoding: result.stderr.isEmpty ? result.stdout : result.stderr, as: UTF8.self).prefix(4000))", evidenceJSON: result.stdout, script: Data(script.utf8))
            }
            let parsed = try Self.parseEvidence(result.stdout, expectedPID: pid, request: request)
            guard try await service.bootIdentity(serial: serial) == expectedBootID,
                  try await processIdentity(service: service, serial: serial, package: package, pid: pid) == initialIdentity else {
                throw InstrumentationError(message: "Gerät oder Prozess hat sich während der Aufnahme geändert; Rohbefund bleibt verfügbar.", evidenceJSON: result.stdout, script: Data(script.utf8))
            }
            try await removeForward(service: service, serial: serial, port: port)
            return InstrumentationCapture(evidenceJSON: result.stdout, script: Data(script.utf8), request: request,
                serial: serial, packageName: package, pid: pid, observedAt: started,
                installedProbeCount: parsed.installed, invocationCount: parsed.invocations,
                warnings: parsed.warnings, summary: parsed.summary)
        } catch {
            var detail = error.localizedDescription
            do { try await removeForward(service: service, serial: serial, port: port) }
            catch { detail += "\nADB-Portweiterleitung tcp:\(port) konnte nicht entfernt werden: \(error.localizedDescription)" }
            throw InstrumentationError(message: detail, evidenceJSON: output, script: Data(script.utf8))
        }
    }

    private func removeForward(service: EmulatorService, serial: String, port: Int) async throws {
        // A cancelled observation still releases its own forwarding rule.
        try await Task.detached { _ = try await service.adb(serial: serial, arguments: ["forward", "--remove", "tcp:\(port)"]) }.value
    }
    private func processIdentity(service: EmulatorService, serial: String, package: String, pid: Int) async throws -> String {
        let command = try await service.adb(serial: serial, arguments: ["exec-out", "cat", "/proc/\(pid)/cmdline"])
        guard !command.truncated, command.stdout.split(separator: 0).first.map({ String(decoding: $0, as: UTF8.self) }) == package else {
            throw AndroidAnalyxerError.failed("PID \(pid) gehört nicht zum gewählten App-Hauptprozess.")
        }
        let stat = try await service.adb(serial: serial, arguments: ["exec-out", "cat", "/proc/\(pid)/stat"])
        guard !stat.truncated, let close = stat.text.lastIndex(of: ")") else { throw AndroidAnalyxerError.failed("Prozessidentität nicht lesbar.") }
        let fields = stat.text[stat.text.index(after: close)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 19, UInt64(fields[19]) != nil else { throw AndroidAnalyxerError.failed("Prozess-Startzeit nicht lesbar.") }
        return String(fields[19])
    }

    private static func readBridge(_ url: URL) throws -> String {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 8 * 1024 * 1024 else {
            throw AndroidAnalyxerError.invalidInput("Eine vorhandene, gebündelte Frida-Java-Bridge (höchstens 8 MiB) auswählen.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func script(request: InstrumentationRequest, bridge: String, package: String, pid: Int) throws -> String {
        try request.validate()
        guard pid > 0, !bridge.isEmpty else { throw AndroidAnalyxerError.invalidInput("PID und Java-Bridge fehlen.") }
        let config = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let expectedPackage = String(decoding: try JSONEncoder().encode(package), as: UTF8.self)
        return bridge + "\n;\n" + #"""
        (() => {
          'use strict';
          const config = \#(config);
          const expectedPackage = \#(expectedPackage);
          const expectedPID = \#(pid);
          const schema = 'android-analyxer.java-probe.v1';
          let calls = 0, capReported = false;
          function emit(event) { try { send(Object.assign({schema, pid: Process.id, time: new Date().toISOString()}, event)); } catch (_) {} }
          function clip(text) { return {text: text.slice(0, config.maxValueCharacters), truncated: text.length > config.maxValueCharacters}; }
          function value(input, type) {
            try {
              if (input === null) return {type, kind:'null'};
              if (type === 'void' || input === undefined) return {type, kind:'void'};
              if (['boolean','byte','char','short','int','long','float','double','java.lang.String'].includes(type))
                return Object.assign({type, kind:'text'}, clip(String(input)));
              if (type === '[B' || type === 'byte[]') {
                const length = input.length, n = Math.min(length, Math.floor(config.maxValueCharacters / 2));
                let hex = ''; for (let i=0; i<n; i++) hex += ('0' + (input[i] & 255).toString(16)).slice(-2);
                return {type, kind:'bytes', text:hex, length, truncated:n < length};
              }
              // No arbitrary toString, getters, stream reads or recursive object traversal.
              return {type, kind:'opaque'};
            } catch (_) { return {type, kind:'unavailable'}; }
          }
          if (Process.id !== expectedPID) { emit({kind:'setup-error',message:'PID mismatch'}); return; }
          if (typeof Java === 'undefined' || !Java.available) { emit({kind:'setup-error',message:'Java bridge or runtime unavailable'}); return; }
          Java.perform(() => {
            try {
              const actualPackage = Java.use('android.app.ActivityThread').currentPackageName();
              if (actualPackage === null || String(actualPackage) !== expectedPackage) {
                emit({kind:'setup-error',message:'Package mismatch'}); return;
              }
              config.probes.forEach((probe, index) => {
                try {
                  const cls = Java.use(probe.className);
                  const method = cls[probe.methodName].overload(...probe.argumentTypes);
                  const returnType = method.returnType.className;
                  method.implementation = function(...args) {
                    if (calls >= config.maxEvents) {
                      if (!capReported) { capReported=true; emit({kind:'limit',maxEvents:config.maxEvents}); }
                      return method.apply(this,args);
                    }
                    const callID = ++calls;
                    emit({kind:'enter',probe:index,callID,threadID:Process.getCurrentThreadId(),arguments:args.map((arg,i)=>value(arg,probe.argumentTypes[i]))});
                    try {
                      const result = method.apply(this,args);
                      emit({kind:'return',probe:index,callID,value:value(result,returnType)});
                      return result;
                    } catch (error) {
                      // Error class only: invoking application-defined toString could change behavior.
                      emit({kind:'throw',probe:index,callID,errorType:error && error.$className ? String(error.$className).slice(0,512) : 'unknown'});
                      throw error;
                    }
                  };
                  emit({kind:'installed',probe:index,className:probe.className,methodName:probe.methodName,argumentTypes:probe.argumentTypes,returnType});
                } catch (error) { emit({kind:'setup-error',probe:index,message:String(error).slice(0,2048)}); }
              });
            } catch (error) { emit({kind:'setup-error',message:String(error).slice(0,2048)}); }
          });
        })();
        """#
    }

    static func parseEvidence(_ data: Data, expectedPID: Int, request: InstrumentationRequest) throws -> (installed: Int, invocations: Int, warnings: [String], summary: String) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let evidence = root["evidence"] as? [String: Any],
              evidence["operation"] as? String == "instrument_with_frida",
              let result = evidence["normalized_result"] as? [String: Any],
              result["pid"] as? Int == expectedPID,
              result["mode"] as? String == "attach",
              let messages = result["messages"] as? [[String: Any]] else {
            throw InstrumentationError(message: "REA lieferte keinen gültigen Instrumentierungsbefund für diese PID.", evidenceJSON: data)
        }
        let events = messages.compactMap { $0["payload"] as? [String: Any] }.filter { $0["schema"] as? String == "android-analyxer.java-probe.v1" }
        let installed = Set(events.filter { $0["kind"] as? String == "installed" }.compactMap { $0["probe"] as? Int })
        let invocations = events.filter { $0["kind"] as? String == "enter" }.count
        let errors = events.filter { $0["kind"] as? String == "setup-error" }.compactMap { $0["message"] as? String }
            + messages.filter { $0["type"] as? String == "error" }.compactMap { $0["description"] as? String }
        guard errors.isEmpty, installed == Set(request.probes.indices) else {
            throw InstrumentationError(message: "Messpunkte nicht vollständig eingerichtet: \(errors.joined(separator: "; ")) (\(installed.count)/\(request.probes.count)).", evidenceJSON: data)
        }
        var warnings = ["Nur ausgewählte Java-Überladungen; keine automatische Vollerfassung des Datenverkehrs. Objekte bleiben opak, Strings und Bytearrays sind begrenzt."]
        if invocations == 0 { warnings.append("Messpunkte eingerichtet, aber im Aufnahmefenster kein Aufruf beobachtet.") }
        if events.contains(where: { $0["kind"] as? String == "limit" }) { warnings.append("Maximale Anzahl beobachteter Aufrufe erreicht; spätere Aufrufe fehlen.") }
        if result["messages_truncated"] as? Bool == true { warnings.append("REA hat die Nachrichtenhistorie gekürzt.") }
        if let cleanup = root["cleanup_error"] ?? result["cleanup_error"], !(cleanup is NSNull) {
            throw InstrumentationError(message: "Frida konnte nicht sauber beendet werden: \(String(describing: cleanup))", evidenceJSON: data)
        }
        let summary = "In-Prozess-Aufnahme · PID \(expectedPID) · \(installed.count) Messpunkte · \(invocations) Aufrufe"
        return (installed.count, invocations, warnings, summary)
    }
}
