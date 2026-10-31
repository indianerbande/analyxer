import Foundation

/// Explicit local tool selection. A Node executable plus REA's `scripts/rea.mjs`
/// avoids reliance on the GUI's PATH; a standalone REA executable also works.
public struct REAConfiguration: Sendable {
    public let executable: URL
    public let cliScript: URL?
    public let jadxJAR: URL?
    public let javaHome: URL?
    public let jadxHeapMiB: Int

    public init(executable: URL, cliScript: URL? = nil, jadxJAR: URL? = nil, javaHome: URL? = nil, jadxHeapMiB: Int = 1024) {
        self.executable = executable; self.cliScript = cliScript
        self.jadxJAR = jadxJAR; self.javaHome = javaHome
        self.jadxHeapMiB = jadxHeapMiB
    }

    public func command(arguments: [String], timeout: TimeInterval = 180,
                        outputLimit: Int = 16 * 1024 * 1024) throws -> Command {
        try Self.checkFile(executable, executable: true)
        if let cliScript { try Self.checkFile(cliScript) }
        if let jadxJAR { try Self.checkFile(jadxJAR) }
        if let javaHome { try Self.checkFile(javaHome.appendingPathComponent("bin/java"), executable: true) }
        guard arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "REA argument contains a null character."))
        }
        guard (128...8192).contains(jadxHeapMiB) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "The JADX memory limit must be between 128 and 8192 MiB."))
        }
        var invocation: [String] = ["REA_JADX_HEAP_MIB=\(jadxHeapMiB)"]
        if let jadxJAR { invocation.append("REA_JADX_MCP_JAR=\(jadxJAR.path)") }
        if let javaHome { invocation.append("JAVA_HOME=\(javaHome.path)") }
        invocation.append(executable.path)
        if let cliScript { invocation.append(cliScript.path) }
        invocation += arguments
        // /usr/bin/env accepts literal arguments; no shell or command interpolation.
        return Command(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: invocation,
                       timeout: timeout, outputLimit: outputLimit)
    }

    private static func checkFile(_ url: URL, executable: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: url.path),
              !executable || FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "REA tool file is missing or unusable: \(url.path)"))
        }
    }
}

public struct REAResult: Sendable {
    public let evidenceJSON: Data
    public let operation: String
    public let apkSHA256: String
    public let observedAt: Date
    public let diagnostics: String
}

/// Keeps the original error object available for project evidence, including
/// provider remediation and partial-observation metadata.
public struct REAExecutionError: LocalizedError, Sendable {
    public let message: String
    public let responseJSON: Data?
    public let diagnostics: String
    public var errorDescription: String? { message }
}

public struct REAService: Sendable {
    public let configuration: REAConfiguration
    private let runner: any CommandRunning
    public init(configuration: REAConfiguration, runner: any CommandRunning = ProcessCommandRunner()) {
        self.configuration = configuration; self.runner = runner
    }

    public func inspectPackage(apk: URL) async throws -> REAResult {
        try await analyze(apk: apk, operation: "inspect_android_package", selectors: [])
    }
    public func searchClasses(apk: URL, query: String) async throws -> REAResult {
        try Self.validateSelector(query, allowEmpty: true)
        return try await analyze(apk: apk, operation: "search_android_classes", selectors: [query])
    }
    public func inspectClass(apk: URL, className: String) async throws -> REAResult {
        try Self.validateSelector(className)
        return try await analyze(apk: apk, operation: "inspect_android_class", selectors: [className])
    }
    public func inspectMethod(apk: URL, className: String, methodName: String,
                              overloadIndex: Int? = nil) async throws -> REAResult {
        try Self.validateSelector(className); try Self.validateSelector(methodName)
        if let overloadIndex, overloadIndex < 0 {
            throw AndroidAnalyxerError.invalidInput(String(localized: "The overload index must be at least 0."))
        }
        var selectors = [className, methodName]
        if let overloadIndex { selectors += ["--overload-index", String(overloadIndex)] }
        return try await analyze(apk: apk, operation: "inspect_android_method", selectors: selectors)
    }

    public func traceReferences(apk: URL, className: String, methodName: String? = nil,
                                overloadIndex: Int? = nil) async throws -> REAResult {
        try Self.validateSelector(className)
        var selectors = [className]
        if let methodName { try Self.validateSelector(methodName); selectors += ["--method-name", methodName] }
        if let overloadIndex {
            guard methodName != nil, overloadIndex >= 0 else {
                throw AndroidAnalyxerError.invalidInput(String(localized: "An overload index needs a selected method; the index must be at least 0."))
            }
            selectors += ["--overload-index", String(overloadIndex)]
        }
        return try await analyze(apk: apk, operation: "trace_android_references", selectors: selectors)
    }

    public func execute(arguments: [String], timeout: TimeInterval = 180,
                        outputLimit: Int = 16 * 1024 * 1024) async throws -> Data {
        try await executeResult(arguments: arguments, timeout: timeout, outputLimit: outputLimit).stdout
    }

    private func analyze(apk: URL, operation: String, selectors: [String]) async throws -> REAResult {
        guard apk.isFileURL, apk.pathExtension.lowercased() == "apk",
              (try? apk.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "Choose an existing single APK for REA."))
        }
        let digest = try ArtifactHash.sha256(apk)
        let result = try await executeResult(arguments: [operation.replacingOccurrences(of: "_", with: "-"), apk.path]
                                             + selectors + ["--format", "json"])
        guard let record = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let id = record["evidence_id"] as? String, id.hasPrefix("ev_"),
              record["operation"] as? String == operation,
              let subject = record["subject"] as? [String: Any],
              let sourceDigest = subject["digest"] as? [String: Any],
              sourceDigest["sha256"] as? String == digest,
              record["limitations"] is [String], record["normalized_result"] != nil else {
            throw REAExecutionError(message: String(localized: "REA did not return a matching, complete APK finding."),
                                    responseJSON: result.stdout, diagnostics: String(decoding: result.stderr, as: UTF8.self))
        }
        guard try ArtifactHash.sha256(apk) == digest else {
            throw AndroidAnalyxerError.failed(String(localized: "The APK was changed during the REA analysis."))
        }
        return REAResult(evidenceJSON: result.stdout, operation: operation, apkSHA256: digest,
                         observedAt: Date(), diagnostics: String(decoding: result.stderr, as: UTF8.self))
    }

    private func executeResult(arguments: [String], timeout: TimeInterval = 180,
                               outputLimit: Int = 16 * 1024 * 1024) async throws -> CommandResult {
        let result = try await runner.run(configuration.command(arguments: arguments, timeout: timeout, outputLimit: outputLimit))
        guard !result.truncated else { throw AndroidAnalyxerError.outputTooLarge }
        let diagnostics = String(decoding: result.stderr, as: UTF8.self)
        guard let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw REAExecutionError(message: String(localized: "REA did not return a valid JSON response (status \(Int(result.status))). \(String(diagnostics.prefix(1000)))"),
                                    responseJSON: nil, diagnostics: diagnostics)
        }
        if let code = object["code"] as? String, let message = object["message"] as? String {
            throw REAExecutionError(message: "REA (\(code)): \(message)", responseJSON: result.stdout, diagnostics: diagnostics)
        }
        guard result.status == 0 else {
            throw REAExecutionError(message: String(localized: "REA failed (status \(Int(result.status))). \(String(diagnostics.prefix(1000)))"),
                                    responseJSON: result.stdout, diagnostics: diagnostics)
        }
        return result
    }

    private static func validateSelector(_ value: String, allowEmpty: Bool = false) throws {
        guard (allowEmpty || !value.isEmpty), value.utf8.count <= 4096,
              !value.hasPrefix("-"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AndroidAnalyxerError.invalidInput(String(localized: "Invalid REA class or method selector."))
        }
    }
}
