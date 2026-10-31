import Foundation
import CryptoKit

public struct ManifestComponent: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public let kind: String
    public let name: String
    public let exported: String?
    public let permission: String?
    public let enabled: String?
    public var actions: [String] = []
    public var categories: [String] = []
    public var data: [[String: String]] = []
    public var exportDescription: String { exported ?? "nicht deklariert" }
}

public struct ManifestSummary: Codable, Sendable {
    public var packageName: String
    public var versionName: String?
    public var versionCode: String?
    public var minSDK: String?
    public var targetSDK: String?
    public var application: [String: String] = [:]
    public var components: [ManifestComponent] = []
    public var permissions: [String] = []

    public static func parse(_ xml: String) throws -> ManifestSummary {
        // No DTDs or entity expansion: the input is an APK-derived, untrusted document.
        guard !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else {
            throw AndroidAnalyxerError.invalidInput("Manifest mit DTD/Entities wird nicht unterstützt.")
        }
        let delegate = ManifestReader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let result = delegate.result, delegate.rootWasManifest,
              result.packageName.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil else {
            throw AndroidAnalyxerError.invalidInput("Android-Manifest ist unvollständig oder ungültig.")
        }
        return result
    }
}

private final class ManifestReader: NSObject, XMLParserDelegate {
    var result: ManifestSummary?
    var stack: [String] = []
    var androidPrefix = "android:"
    var component: ManifestComponent?
    var rootWasManifest = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let parent = stack.last
        stack.append(name)
        if stack.count == 1 {
            rootWasManifest = name == "manifest"
            for (key, value) in attributes where key.hasPrefix("xmlns:") && value == "http://schemas.android.com/apk/res/android" {
                androidPrefix = String(key.dropFirst(6)) + ":"
            }
        }
        let attrs = Dictionary(uniqueKeysWithValues: attributes.compactMap { key, value in
            key.hasPrefix(androidPrefix) ? (String(key.dropFirst(androidPrefix.count)), value) : nil
        })
        if name == "manifest", stack.count == 1 {
            result = ManifestSummary(packageName: attributes["package"] ?? "", versionName: attrs["versionName"], versionCode: attrs["versionCode"])
        } else if name == "uses-sdk", parent == "manifest" {
            result?.minSDK = attrs["minSdkVersion"]; result?.targetSDK = attrs["targetSdkVersion"]
        } else if name.hasPrefix("uses-permission"), parent == "manifest", let permission = attrs["name"] {
            result?.permissions.append(permission)
        } else if name == "application", parent == "manifest" {
            result?.application = attrs
        } else if ["activity", "activity-alias", "service", "receiver", "provider"].contains(name), parent == "application", let raw = attrs["name"], let package = result?.packageName {
            let fullName = raw.hasPrefix(".") ? package + raw : (raw.contains(".") ? raw : package + "." + raw)
            component = ManifestComponent(kind: name, name: fullName, exported: attrs["exported"], permission: attrs["permission"] ?? result?.application["permission"], enabled: attrs["enabled"])
        } else if parent == "intent-filter", component != nil {
            if name == "action", let action = attrs["name"] { component?.actions.append(action) }
            if name == "category", let category = attrs["name"] { component?.categories.append(category) }
            if name == "data" { component?.data.append(attrs) }
        }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count == 3, component?.kind == name, let value = component { result?.components.append(value); component = nil }
        _ = stack.popLast()
    }
}

public struct StaticAnalysis: Codable, Sendable {
    public let observedAt: Date
    public let apk: APKReport
    public let manifest: ManifestSummary
    public let manifestXML: String
    public let dexInventory: String
    public let tools: [String: String]
    public let limitations: [String]

    public var reportText: String {
        var lines = ["ANDROID ANALYXER · STATISCHE ANALYSE", "Zeit: \(observedAt.ISO8601Format())", "SHA-256: \(apk.sha256)",
                     "Paket: \(manifest.packageName)", "Version: \(manifest.versionName ?? "unbekannt") (\(manifest.versionCode ?? "?"))",
                     "minSdk: \(manifest.minSDK ?? "nicht deklariert") · targetSdk: \(manifest.targetSDK ?? "nicht deklariert")", "", "WERKZEUGE"]
        lines += tools.keys.sorted().map { "\($0): \(tools[$0]!)" }
        lines += ["", "BERECHTIGUNGEN"] + apk.permissions
        lines += ["", "APPLICATION-ATTRIBUTE"] + manifest.application.keys.sorted().map { "\($0)=\(manifest.application[$0]!)" }
        lines += ["", "KOMPONENTEN (exported ist der deklarierte Wert, keine Erreichbarkeitsprüfung)"]
        for item in manifest.components {
            lines += ["\(item.kind): \(item.name)", "  exported=\(item.exportDescription), enabled=\(item.enabled ?? "nicht deklariert"), permission=\(item.permission ?? "keine deklariert")"]
            lines += item.actions.map { "  action: \($0)" } + item.categories.map { "  category: \($0)" }
            for data in item.data { lines.append("  data: " + data.keys.sorted().map { "\($0)=\(data[$0]!)" }.joined(separator: ", ")) }
        }
        lines += ["", "GRENZEN"] + limitations + ["", "AAPT2-METADATEN", apk.metadata, "", "DEX-INVENTAR", dexInventory]
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum ArtifactHash {
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension EmulatorService {
    public func staticAnalysis(apk: URL) async throws -> StaticAnalysis {
        // Analyse only the project's immutable input copy, then verify its bytes again.
        async let base = inspectAPK(at: apk)
        async let xml = execute(tool: paths.apkanalyzer, name: "apkanalyzer (Command-line Tools + Java)", arguments: ["manifest", "print", apk.path], timeout: 90)
        let (report, xmlResult) = try await (base, xml)
        guard !xmlResult.truncated else { throw AndroidAnalyxerError.outputTooLarge }
        let summary = try ManifestSummary.parse(xmlResult.text)
        var limitations = [
            "Statische Deklarationen belegen kein Laufzeitverhalten und sind keine Sicherheitsbewertung.",
            "Nicht deklarierte exported-/enabled-Werte bleiben offen; Android-Version, targetSdk und Berechtigungen beeinflussen die tatsächliche Erreichbarkeit.",
            "DEX-Inventar listet Klassen und Methoden; keine Java-/Kotlin-Dekompilierung. Dynamisch geladener Code ist nicht erfasst.",
            "JADX, native REA-Dekompilierung und Netzwerkmitschnitte sind in dieser Ausbaustufe nicht integriert."
        ]
        var dex = ""
        do {
            let result = try await execute(tool: paths.apkanalyzer, name: "apkanalyzer", arguments: ["dex", "packages", "--defined-only", apk.path], timeout: 120)
            dex = result.text
            if result.truncated { limitations.append("DEX-Ausgabe auf 4 MiB begrenzt; Inventar unvollständig.") }
        } catch { limitations.append("DEX-Inventar nicht verfügbar: \(error.localizedDescription)") }
        var versions: [String: String] = [:]
        if let tool = paths.aapt2 {
            let version = try await execute(tool: tool, name: "aapt2", arguments: ["version"])
            let text = (version.text + String(decoding: version.stderr, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            versions["aapt2"] = text.isEmpty ? "Version unbekannt" : text
        }
        if let tool = paths.apkanalyzer {
            let properties = tool.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("source.properties")
            let source = (try? String(contentsOf: properties, encoding: .utf8)) ?? ""
            versions["apkanalyzer"] = source.components(separatedBy: .newlines).first { $0.hasPrefix("Pkg.Revision") } ?? "Version unbekannt"
            versions["apkanalyzer-Pfad"] = tool.path
        }
        let endingHash = try await Task.detached { try ArtifactHash.sha256(apk) }.value
        guard endingHash == report.sha256 else { throw AndroidAnalyxerError.failed("Die APK wurde während der Analyse verändert.") }
        return StaticAnalysis(observedAt: Date(), apk: report, manifest: summary, manifestXML: xmlResult.text, dexInventory: dex, tools: versions, limitations: limitations)
    }
}
