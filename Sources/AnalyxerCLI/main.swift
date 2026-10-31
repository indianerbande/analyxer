import Foundation
import AnalyxerCore
import Darwin

@main
struct AnalyxerCLI {
    static func main() async {
        do {
            try await execute(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func execute(_ arguments: [String]) async throws {
        let paths = SDKPaths.discover()
        let service = EmulatorService(paths: paths)
        switch arguments.first {
        case "play-images" where arguments.count == 1:
            for image in PlayDeviceService(service: service).installedImages() { print("\(image.api) | \(image.package)") }
        case "play-create" where arguments.count == 3:
            let play = PlayDeviceService(service: service)
            guard let image = play.installedImages().first(where: { $0.api == arguments[2] }) else { throw AnalyxerError.invalidInput("Installed Play image not found.") }
            let device = try await play.create(name: arguments[1], image: image)
            print("\(device.name) | \(device.home!.path)")
        case "installed-import" where arguments.count == 4:
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("analyxer-import-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let capture = try await service.captureInstalledApp(serial: arguments[1], package: arguments[2], to: temporary)
            let store = try await ProjectStore.create(at: URL(fileURLWithPath: arguments[3]), apk: capture.baseAPK, service: service, installed: capture)
            let workflow = ProjectWorkflow(store: store, service: service)
            let session = try await workflow.begin(serial: arguments[1])
            do { try await workflow.adoptInstalled(sessionID: session.id) }
            catch { try? await store.endSession(session.id); throw error }
            try await store.endSession(session.id)
            print("Project: \(store.directory.path) · \(capture.files.count) APKs · \(capture.source.package)")
        case "project-record" where arguments.count == 5:
            guard let kind = EvidenceKind(rawValue: arguments[2]), [.rea, .note, .staticReport, .networkReport, .networkCapture, .logcat].contains(kind) else { throw AnalyxerError.invalidInput("Unsupported evidence type for import.") }
            let store = try await ProjectStore.open(at: URL(fileURLWithPath: arguments[1]))
            let source = URL(fileURLWithPath: arguments[4])
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 32 * 1024 * 1024 else { throw AnalyxerError.outputTooLarge }
            let data = try Data(contentsOf: source)
            if kind == .networkCapture { _ = try PCAPInspector.inspect(data) }
            let item = try await store.record(kind: kind, summary: arguments[3], data: data)
            print("\(item.id) · \(item.relativePath) · \(item.sha256)")
        case "installed-smoke" where arguments.count == 4:
            guard arguments[1].range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil, arguments[2] == "lab.analyxer.fixture" else { throw AnalyxerError.invalidInput("The smoke test only supports the project's own synthetic fixture on an explicit emulator.") }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("analyxer-import-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let capture = try await service.captureInstalledApp(serial: arguments[1], package: arguments[2], to: temporary)
            let store = try await ProjectStore.create(at: URL(fileURLWithPath: arguments[3]), apk: capture.baseAPK, service: service, installed: capture)
            let workflow = ProjectWorkflow(store: store, service: service)
            let session = try await workflow.begin(serial: arguments[1])
            try await workflow.adoptInstalled(sessionID: session.id)
            try await workflow.launch(sessionID: session.id)
            try await workflow.captureScreenshot(sessionID: session.id)
            try await store.endSession(session.id)
            try await store.export(to: URL(fileURLWithPath: arguments[3] + "-export"))
            print(try await store.combinedReport())
        case "care" where arguments.count == 2:
            let care = DeviceCareService(service: service)
            let (apps, storage) = try await care.inventory(serial: arguments[1])
            let mb = { (bytes: Int64?) in bytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "?" }
            if let storage { print("Storage: \(mb(storage.used)) used, \(mb(storage.free)) free of \(mb(storage.total)); apps \(mb(storage.apps)), data \(mb(storage.appData)), cache \(mb(storage.appCache)), system \(mb(storage.system))") }
            print("Apps: \(apps.count), of which system \(apps.filter(\.isSystem).count), protected \(apps.filter(\.isProtected).count), disabled \(apps.filter(\.isDisabled).count), removed for user \(apps.filter(\.isRemovedForUser).count)")
            for app in apps.prefix(12) {
                print("\(app.package) | \(mb(app.totalBytes)) (app \(mb(app.appBytes)), data \(mb(app.dataBytes)), cache \(mb(app.cacheBytes))) | \(app.source)\(app.isSystem ? " | system" : "")\(app.isProtected ? " | protected" : "")\(app.isDisabled ? " | disabled" : "") | last used \(app.lastUsed.map { $0.formatted(date: .numeric, time: .shortened) } ?? "–")")
            }
            let leftovers = try await care.leftovers(serial: arguments[1], known: Set(apps.map(\.package)))
            print("App leftovers: \(leftovers.count)")
            for leftover in leftovers { print("\(leftover.path) | \(mb(leftover.bytes))") }
        case "care-smoke" where arguments.count == 2:
            // Only for an explicitly chosen, disposable emulator: every care action runs once and is checked.
            let serial = arguments[1], probe = "com.google.android.youtube", leftover = "com.example.analyxer.leftover"
            guard serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil else { throw AnalyxerError.invalidInput("care-smoke only runs on an explicit emulator.") }
            let care = DeviceCareService(service: service)
            func app(_ package: String) async throws -> InstalledApp? { try await care.inventory(serial: serial).apps.first { $0.package == package } }
            func check(_ ok: Bool, _ step: String) throws { guard ok else { throw AnalyxerError.failed("care-smoke: \(step) failed") }; print("OK  \(step)") }
            try check(try await app(probe).map { !$0.isProtected && $0.isSystem && !$0.isDisabled && !$0.isRemovedForUser } ?? false, "inventory: \(probe) present, changeable")
            try await care.setEnabled(false, package: probe, serial: serial); try check(try await app(probe)?.isDisabled == true, "disable")
            try await care.setEnabled(true, package: probe, serial: serial); try check(try await app(probe)?.isDisabled == false, "enable")
            try await care.removeForUser(package: probe, serial: serial); try check(try await app(probe)?.isRemovedForUser == true, "remove for user")
            try await care.restoreForUser(package: probe, serial: serial); try check(try await app(probe)?.isRemovedForUser == false, "restore")
            do { try await care.setEnabled(false, package: "com.android.systemui", serial: serial); try check(false, "protection") } catch AnalyxerError.invalidInput { print("OK  protection: com.android.systemui refused") }
            do { try await care.uninstall(package: probe, serial: serial); try check(false, "uninstall lock") } catch AnalyxerError.invalidInput { print("OK  preinstalled app cannot be uninstalled") }
            try await care.trimCaches(serial: serial); print("OK  caches cleared")
            guard let adb = paths.adb else { throw AnalyxerError.missingTool("adb") }
            _ = try await ProcessCommandRunner().run(Command(executable: adb, arguments: ["-s", serial, "shell", "mkdir", "-p", "/sdcard/Android/data/\(leftover)/files"]))
            let known = Set(try await care.inventory(serial: serial).apps.map(\.package))
            let found = try await care.leftovers(serial: serial, known: known).filter { $0.package == leftover }
            try check(found.count == 1, "app leftover found")
            try await care.delete(found[0], serial: serial)
            try check(try await care.leftovers(serial: serial, known: known).allSatisfy { $0.package != leftover }, "app leftover deleted")
        case "diagnose" where arguments.count == 1:
            print("SDK: \(paths.root.path)")
            print("adb: \(paths.adb?.path ?? "missing")")
            print("emulator: \(paths.emulator?.path ?? "missing")")
            print("aapt2: \(paths.aapt2?.path ?? "missing")")
            for diagnostic in paths.diagnostics { print("Note: \(diagnostic)") }
            if paths.emulator != nil {
                let avds = try await service.avds()
                print("AVDs (\(avds.count)):")
                for avd in avds { print("  \(avd.name)") }
            }
            if paths.adb != nil {
                let devices = try await service.devices()
                print("Devices (\(devices.count)):")
                for device in devices {
                    print("  \(device.serial) | \(device.state) | \(device.model) | AVD: \(device.avdName ?? "–")")
                }
            }
            guard paths.adb != nil, paths.emulator != nil, paths.aapt2 != nil else {
                throw AnalyxerError.failed("The Android SDK is not fully set up.")
            }
        case "inspect" where arguments.count == 2:
            printReport(try await service.inspectAPK(at: URL(fileURLWithPath: arguments[1])))
        case "project-create" where arguments.count == 3:
            let store = try await ProjectStore.create(at: URL(fileURLWithPath: arguments[2]), apk: URL(fileURLWithPath: arguments[1]), service: service)
            print(try await store.combinedReport())
            print("Project: \(store.directory.path)")
        case "setup" where arguments.count >= 2:
            // setup check|licenses|install jdk|node|rea|jadx|frida-bridge|frida-server|android-sdk|all [--tools DIR] [--sdk DIR] [--profile FILE] [--accept-android-licenses] [--play-image]
            var options: [String: String] = [:], flags: Set<String> = [], rest: [String] = []
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if ["--tools", "--sdk", "--profile"].contains(argument), index + 1 < arguments.count { options[argument] = arguments[index + 1]; index += 2; continue }
                if argument.hasPrefix("--") { flags.insert(argument) } else { rest.append(argument) }
                index += 1
            }
            let setup = ToolSetupService(toolsFolder: options["--tools"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                                         sdkRoot: options["--sdk"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? paths.root,
                                         configured: try options["--profile"].map { try AnalysisTools.load(URL(fileURLWithPath: $0)) } ?? AnalysisTools())
            switch rest.first {
            case "check":
                for status in await setup.check() {
                    print("\(status.id.cliName.padding(toLength: 13, withPad: " ", startingAt: 0)) \(String(describing: status.state).padding(toLength: 9, withPad: " ", startingAt: 0)) \(status.version ?? "-") · \(status.location?.path ?? "-")\(status.note.map { " · " + $0 } ?? "")")
                }
            case "licenses":
                let text = try await setup.androidLicenses()
                print(text.isEmpty ? "All Android SDK licences are accepted." : text)
            case "install" where rest.count == 2:
                let tools = rest[1] == "all" ? ToolID.allCases : [try ToolID.allCases.first { [$0.rawValue.lowercased(), $0.cliName].contains(rest[1].lowercased()) }.orThrow(AnalyxerError.invalidInput("Unknown tool \(rest[1])."))]
                for tool in tools {
                    if tool == .androidSDK {
                        let pending = flags.contains("--accept-android-licenses") ? "" : try await setup.androidLicenses()
                        guard pending.isEmpty else {
                            throw AnalyxerError.invalidInput("Read the licences with `setup licenses`, then repeat with --accept-android-licenses.")
                        }
                        if flags.contains("--accept-android-licenses") { try await setup.acceptAndroidLicenses() }
                    }
                    print("== \(tool.cliName)")
                    try await setup.install(tool, includePlayImage: flags.contains("--play-image")) { message, fraction in
                        if fraction == nil || fraction == 0 { print(message) }
                    }
                }
                for status in await setup.check() where tools.contains(status.id) { print("\(status.id.cliName): \(status.state) \(status.version ?? "")") }
            default:
                throw AnalyxerError.invalidInput("Usage: setup check|licenses|install jdk|node|rea|jadx|frida-bridge|frida-server|android-sdk|all [--tools DIR] [--sdk DIR] [--profile FILE] [--accept-android-licenses] [--play-image]")
            }
        case "profile" where arguments.count == 2:
            let store = try await ProjectStore.open(at: URL(fileURLWithPath: arguments[1]))
            let profile = try await AppProfileService().profile(project: await store.snapshot(), root: store.directory)
            print("\(profile.title) · \(profile.packageName) · Version \(profile.versionName ?? "?")")
            print("Runs on Android \(profile.minAndroid ?? "?") (API \(profile.minSDK ?? "?")) and later · targets Android \(profile.targetAndroid ?? "?") (API \(profile.targetSDK ?? "?")) · \(profile.apkCount) APKs, \(profile.totalBytes / 1_048_576) MB")
            print("Technology: \((profile.frameworks.isEmpty ? ["Java/Kotlin"] : profile.frameworks).joined(separator: ", ")) · \(profile.abis.joined(separator: ", ")) · \(profile.nativeLibraryCount) native libraries\(profile.dexInventoryTruncated ? " · DEX inventory truncated" : "")")
            print("Notable: " + profile.highlights.map { ($0.notable ? "! " : "") + $0.text }.joined(separator: " | "))
            for (group, items) in profile.permissionsByGroup { print("[\(group)] " + items.map { "\($0.label) (\($0.level.title))" }.joined(separator: "; ")) }
            for (category, items) in profile.sdksByCategory { print("<\(category)> " + items.map { "\($0.name) [\($0.sources.joined(separator: ", "))]" }.joined(separator: "; ")) }
            print("Reachable from outside: " + profile.reachable.map(\.title).joined(separator: ", ") + " · Web links: \(profile.webLinkHosts.joined(separator: ", ")) · Schemes: \(profile.linkSchemes.joined(separator: ", "))")
        case "project-info" where arguments.count == 2:
            let store = try await ProjectStore.open(at: URL(fileURLWithPath: arguments[1]))
            print(try await store.combinedReport())
        case "rea-method" where arguments.count == 6:
            let store = try await ProjectStore.open(at: URL(fileURLWithPath: arguments[1]))
            let tools = try AnalysisTools.load(URL(fileURLWithPath: arguments[2]))
            guard let overload = Int(arguments[5]), overload >= 0 else { throw AnalyxerError.invalidInput("Overload index required.") }
            let workflow = ProjectWorkflow(store: store, service: service)
            let item = try await workflow.analyzeCode(using: REAService(configuration: tools.configuration()),
                query: .method(className: arguments[3], methodName: arguments[4], overload: overload))
            print(REAPresentation.text(try await store.evidenceData(id: item.id)))
        case "analysis-smoke" where arguments.count == 5:
            let serial = arguments[1], fixture = "lab.analyxer.fixture"
            guard serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil else { throw AnalyxerError.invalidInput("Explicit test emulator required.") }
            let apk = URL(fileURLWithPath: arguments[2]), directory = URL(fileURLWithPath: arguments[3])
            let preliminary = try await service.inspectAPK(at: apk)
            guard preliminary.metadata.contains("package: name='\(fixture)'") else { throw AnalyxerError.invalidInput("Only the synthetic TLS fixture is allowed.") }
            let tools = try AnalysisTools.load(URL(fileURLWithPath: arguments[4]))
            let store = try await ProjectStore.create(at: directory, apk: apk, service: service)
            let workflow = ProjectWorkflow(store: store, service: service)
            let rea = try REAService(configuration: tools.configuration())
            let code = try await workflow.analyzeCode(using: rea, query: .method(className: fixture + ".MainActivity", methodName: "buildRequest", overload: 0))
            guard REAPresentation.text(try await store.evidenceData(id: code.id)).contains("synthetic") else { throw AnalyxerError.failed("Decompiled request construction is missing.") }
            let session = try await workflow.begin(serial: serial)
            try await workflow.install(sessionID: session.id)
            try await workflow.launch(sessionID: session.id)
            let request = InstrumentationRequest(probes: [
                JavaMethodProbe(className: fixture + ".MainActivity", methodName: "buildRequest", argumentTypes: ["java.lang.String"]),
                JavaMethodProbe(className: fixture + ".MainActivity", methodName: "consumeResponse", argumentTypes: ["java.lang.String"])
            ], durationMilliseconds: 20_000)
            let instrumentation = try InstrumentationService(rea: tools.configuration(), bridgeURL: tools.bridgeURL())
            guard let adb = paths.adb else { throw AnalyxerError.failed("ADB is missing.") }
            async let recording: Void = workflow.observeProcess(sessionID: session.id, instrumentation: instrumentation, request: request)
            try await Task.sleep(for: .seconds(5))
            let trigger = try await ProcessCommandRunner().run(Command(executable: adb, arguments: ["-s", serial, "shell", "am", "start", "-W", "-f", "536870912", "-n", fixture + "/.MainActivity", "--ez", "run_tls", "true"]))
            guard trigger.status == 0 else { throw AnalyxerError.failed("The TLS test could not be triggered.") }
            try await recording
            try await store.endSession(session.id)
            let snapshot = await store.snapshot()
            guard let captured = snapshot.evidence.first(where: { $0.kind == .instrumentation }) else { throw AnalyxerError.failed("No process finding saved.") }
            let raw = try await store.evidenceData(id: captured.id)
            let text = REAPresentation.text(raw)
            guard text.contains("fixture-request-"), text.contains("fixture-response"), text.contains("consumeResponse"), text.contains("buildRequest") else {
                throw AnalyxerError.failed("Plain text before sending and after TLS receipt was not fully observed. Findings remain in the project.")
            }
            let export = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-export")
            try await store.export(to: export)
            let reopened = try await ProjectStore.open(at: export)
            guard try await reopened.evidenceData(id: captured.id) == raw else { throw AnalyxerError.failed("Process finding changed in the export.") }
            print("ANALYSIS SMOKE PASSED: REA decompilation, Frida inputs/returns before sending and after real local TLS receipt, project/export round trip.\nProject: \(directory.path)\nFindings: \(snapshot.evidence.count)")
        case "project-smoke" where arguments.count == 4:
            let serial = arguments[1], fixture = "lab.analyxer.fixture"
            guard serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil else {
                throw AnalyxerError.invalidInput("The project smoke test needs an explicit emulator target.")
            }
            let source = URL(fileURLWithPath: arguments[2])
            let preliminary = try await service.inspectAPK(at: source)
            guard preliminary.metadata.contains("package: name='\(fixture)'") else { throw AnalyxerError.invalidInput("Only the synthetic fixture is allowed.") }
            let directory = URL(fileURLWithPath: arguments[3])
            let store = try await ProjectStore.create(at: directory, apk: source, service: service)
            let workflow = ProjectWorkflow(store: store, service: service)
            let session = try await workflow.begin(serial: serial)
            try await workflow.install(sessionID: session.id)
            try await workflow.launch(sessionID: session.id)
            try await workflow.navigate(sessionID: session.id, keyCode: 3)
            try await workflow.launch(sessionID: session.id)
            try await Task.sleep(for: .seconds(1))
            try await workflow.captureLogs(sessionID: session.id)
            try await workflow.captureScreenshot(sessionID: session.id)
            try await store.addNote("Synthetic end-to-end test: installation, launch, Home, relaunch, app Logcat and screenshot.", sessionID: session.id)
            try await store.endSession(session.id)
            let reopened = try await ProjectStore.open(at: directory)
            let saved = await reopened.snapshot()
            guard saved.sessions.count == 1, saved.sessions[0].endedAt != nil,
                  let log = saved.evidence.first(where: { $0.kind == .logcat }),
                  saved.evidence.contains(where: { $0.kind == .screenshot }) else { throw AnalyxerError.failed("The saved session is incomplete.") }
            let logURL = try await reopened.evidenceURL(id: log.id)
            guard try String(contentsOf: logURL, encoding: .utf8).contains("AnalyxerFixture") else { throw AnalyxerError.failed("The expected fixture log message is missing.") }
            let export = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-export")
            try await reopened.export(to: export)
            let imported = try await ProjectStore.open(at: export)
            guard await imported.snapshot().evidence.count == saved.evidence.count else { throw AnalyxerError.failed("Export round trip incomplete.") }
            print("PROJECT SMOKE PASSED: \(saved.evidence.count) findings, Android \(session.device.properties["ro.build.version.release"] ?? "?")")
            print("Project: \(directory.path)\nExport: \(export.path)")
        case "smoke" where arguments.count == 4:
            let serial = arguments[1]
            guard serial.range(of: #"^emulator-[0-9]+$"#, options: .regularExpression) != nil else {
                throw AnalyxerError.invalidInput("The smoke test needs an explicit emulator serial (emulator-PORT).")
            }
            let apk = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            let output = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
            let report = try await service.inspectAPK(at: apk)
            let fixtureID = "lab.analyxer.fixture"
            guard report.metadata.split(whereSeparator: \.isNewline).contains(where: {
                $0.hasPrefix("package: name='\(fixtureID)'")
            }) else {
                throw AnalyxerError.invalidInput("The smoke test only accepts the synthetic APK lab.analyxer.fixture.")
            }
            guard try await service.devices().contains(where: { $0.serial == serial && $0.isOnline }) else {
                throw AnalyxerError.failed("The explicitly chosen emulator \(serial) is not online.")
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            print("Smoke test: \(serial), synthetic fixture \(fixtureID)")
            printReport(report)
            try report.metadata.write(to: output.appendingPathComponent("apk-metadata.txt"), atomically: true, encoding: .utf8)
            print("Installation: \(try await service.install(apk: apk, serial: serial).trimmingCharacters(in: .whitespacesAndNewlines))")
            let packages = try await service.packages(serial: serial)
            guard packages.contains(fixtureID) else {
                throw AnalyxerError.failed("The fixture was not found in the package list after installation.")
            }
            try packages.joined(separator: "\n").write(to: output.appendingPathComponent("packages.txt"), atomically: true, encoding: .utf8)
            print("Package list: fixture found (\(packages.count) packages).")
            print("App launch: \(try await service.launchPackage(identifier: fixtureID, serial: serial))")
            try await service.keyevent(serial: serial, keyCode: 3)
            print("Navigation: Home pressed.")
            print("Relaunch: \(try await service.launchPackage(identifier: fixtureID, serial: serial))")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let screenshot = try await service.screenshot(serial: serial)
            try screenshot.write(to: output.appendingPathComponent("screenshot.png"), options: .atomic)
            let logs = try await service.logs(serial: serial)
            try logs.write(to: output.appendingPathComponent("logcat.txt"), atomically: true, encoding: .utf8)
            print("Smoke test passed. Screenshot: \(screenshot.count) bytes. Results: \(output.path)")
        default:
            throw AnalyxerError.invalidInput("Usage: analyxer-cli setup check|licenses|install … | profile PROJECT | care SERIAL | care-smoke EMULATOR-SERIAL | installed-import SERIAL PACKAGE NEW-FOLDER | project-record PROJECT KIND SUMMARY FILE | play-images | play-create NAME API | installed-smoke EMULATOR-SERIAL lab.analyxer.fixture NEW-FOLDER | diagnose | inspect APK | project-create APK FOLDER | project-info FOLDER | rea-method PROJECT TOOL-PROFILE CLASS METHOD OVERLOAD | analysis-smoke EMULATOR-SERIAL TLS-FIXTURE NEW-FOLDER TOOL-PROFILE | project-smoke EMULATOR-SERIAL SYNTHETIC-APK NEW-FOLDER | smoke EMULATOR-SERIAL SYNTHETIC-APK OUTPUT-FOLDER")
        }
    }

    private static func printReport(_ report: APKReport) {
        print(report.metadata)
        print("Permissions: \(report.permissions.joined(separator: ", "))")
        print("SHA-256: \(report.sha256)")
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}


private extension ToolID {
    /// Command-line spelling, e.g. `frida-server`.
    var cliName: String { rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased() }
}
