import Foundation

/// Portable tool profile contains paths, never credentials. Loading a profile
/// selects tools; execution only occurs through an explicit analysis action.
public struct AnalysisTools: Codable, Sendable, Equatable {
    public var executable: String = ""
    public var cliScript: String = ""
    public var jadxJAR: String = ""
    public var javaHome: String = ""
    public var javaBridge: String = ""
    public init() {}
    public static func load(_ url: URL) throws -> AnalysisTools {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular else { throw AndroidAnalyxerError.invalidInput("Werkzeugprofil muss eine reguläre Datei sein.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count < 64 * 1024 {
            guard let part = try handle.read(upToCount: 64 * 1024 - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        guard data.count < 64 * 1024 else { throw AndroidAnalyxerError.outputTooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func configuration() throws -> REAConfiguration {
        guard let executable = try path(self.executable) else { throw AndroidAnalyxerError.invalidInput("Bitte ein lokales REA-Werkzeugprofil laden oder REA/Node auswählen.") }
        return REAConfiguration(executable: executable, cliScript: try path(cliScript), jadxJAR: try path(jadxJAR), javaHome: try path(javaHome))
    }
    public func bridgeURL() throws -> URL {
        guard let url = try path(javaBridge) else { throw AndroidAnalyxerError.invalidInput("Die kompilierte Frida-Java-Bridge fehlt im Werkzeugprofil.") }
        return url
    }
    private func path(_ value: String) throws -> URL? {
        if value.isEmpty { return nil }
        guard value.hasPrefix("/"), !value.contains("\0") else { throw AndroidAnalyxerError.invalidInput("Werkzeugpfade müssen absolut sein.") }
        return URL(fileURLWithPath: value)
    }
}

public enum REAQuery: Sendable {
    case package
    case classes(String)
    case members(String)
    case method(className: String, methodName: String, overload: Int?)
    case references(className: String, methodName: String?, overload: Int?)
}

extension ProjectWorkflow {
    @discardableResult
    public func analyzeCode(using rea: REAService, query: REAQuery, componentPath: String? = nil) async throws -> ProjectEvidence {
        do {
            let apk = try await store.verifiedAPKComponent(path: componentPath ?? "input/application.apk")
            let result: REAResult
            switch query {
            case .package: result = try await rea.inspectPackage(apk: apk)
            case .classes(let query): result = try await rea.searchClasses(apk: apk, query: query)
            case .members(let name): result = try await rea.inspectClass(apk: apk, className: name)
            case .method(let name, let method, let overload):
                result = try await rea.inspectMethod(apk: apk, className: name, methodName: method, overloadIndex: overload)
            case .references(let name, let method, let overload):
                result = try await rea.traceReferences(apk: apk, className: name, methodName: method, overloadIndex: overload)
            }
            return try await store.record(kind: .rea, summary: "\(apk.lastPathComponent) · \(result.operation)", data: result.evidenceJSON)
        } catch {
            var detail = error.localizedDescription
            if let error = error as? REAExecutionError {
                if let data = error.responseJSON { detail += "\n" + String(decoding: data, as: UTF8.self) }
                detail += "\n" + error.diagnostics
            }
            try await store.record(kind: .failure, summary: "REA-Codeanalyse", data: Data(detail.utf8))
            throw error
        }
    }
}

/// Human-readable projection; raw JSON remains the evidence of record.
public enum REAPresentation {
    public static func text(_ data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return String(decoding: data, as: UTF8.self) }
        let record = object["evidence"] as? [String: Any] ?? object
        var lines: [String] = []
        if let error = object["cleanup_error"], !(error is NSNull) { lines.append("Aufräumen unvollständig: \(render(error))") }
        for key in ["evidence_id", "operation", "authority", "confidence", "provider", "limitations"] {
            if let value = record[key] { lines.append("\(key): \(render(value))") }
        }
        lines.append("\nBEFUNDE\n" + render(record["normalized_result"] ?? record))
        return lines.joined(separator: "\n\n")
    }
    private static func render(_ value: Any, depth: Int = 0) -> String {
        guard depth < 20 else { return "[Weitere Struktur im JSON-Befund]" }
        if let string = value as? String { return string }
        if let array = value as? [Any] { return array.map { render($0, depth: depth + 1) }.joined(separator: "\n\n") }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { "\($0): \(render(dictionary[$0]!, depth: depth + 1))" }.joined(separator: "\n")
        }
        return String(describing: value)
    }
}
