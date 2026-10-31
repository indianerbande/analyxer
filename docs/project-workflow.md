# Analysis projects

[Deutsch](de/project-workflow.md)

A project links exactly one app version (a single APK or an installed base/split set) with static findings and any number of documented test sessions. The APK is copied when the project is created. Analysis, later installation and export use this copy, so the original can be moved afterwards.

## Workflow

1. **Open APK … / New Project from APK …:** choose an APK and a new project folder. The folder must not exist yet. The extension `.androidlab` is a naming convention; the project is an ordinary folder.
2. **App profile:** the project opens with a plain-language profile (versions, size, technology, permissions, libraries, what is reachable from outside). The report, the complete manifest, the DEX inventory and all components are under **Details & Evidence**. Components can be filtered by name and type. `exported` is shown as the explicit manifest value; a missing value is not read as `false`.
3. **Start Test Session:** choose a fully started Android device. Its serial, AVD name (if available), Android and SDK version, ABI, model, build fingerprint, boot ID and ADB version are stored.
4. **Install project APK → Launch Project App:** only the project APK is installed and only its package is launched. A launch within the project needs a confirmed installation in the same session.
5. **Observe:** take screenshots, save the app logcat and navigate from the project section. Successful actions and errors are stored immediately as separate findings. **Save Note** keeps your notes.
6. **End Session / continue later:** reopen the project; earlier findings stay visible. Runtime actions need a new, explicitly started session. A device change or an Android restart under the same ADB serial is detected through the boot ID.
7. **Export All …:** choose a new target folder. It contains the APKs, the project index, all referenced evidence files and `report.txt` with the static report, session data, actions and notes. The export can be opened as a project again.

The pages Devices, Installed Apps and Logcat remain separate tools. Only actions in **Analysis Projects** are recorded in a project automatically. Screenshots show the whole device screen. The app logcat is filtered to the current main process, does not include secondary processes and is a limited snapshot; older entries with the same PID can be included.

Files written into the project (reports, evidence summaries, `report.txt`) are always in English, whatever the interface language, so a project reads the same everywhere. Projects created by older versions keep their existing texts.

## Storage and integrity

```text
Example.androidlab/
  project.json                 # schema 1/2/3, revision, APK identity, analysis, sessions, evidence index
  input/application.apk        # the project's own copy of the APK
  input/split-1.apk            # optional: further APKs, each with SHA-256
  evidence/<UUID>.txt          # reports, DEX, actions, logs, notes, errors
  evidence/<UUID>.xml          # decoded manifest
  evidence/<UUID>.png          # screenshots
  .write-lock                  # local write coordination; not exported
  report.txt                   # additional combined report in the export
```

Timestamps are stored in UTC/ISO 8601 and shown in local time. Every finding is bound to a timestamp, a SHA-256 and optionally a test session. Static reports are not marked as runtime observations.

- Creating and exporting happen in a new temporary sibling folder that is moved to the target only after success. Existing projects are never overwritten.
- The project index is replaced atomically. A local file lock and a revision number prevent a stale second instance from overwriting newer findings.
- Project files are addressed only through validated relative paths. Path traversal and symbolic links are refused.
- The APK is checked against its stored hash when the project is reopened and before installation. Evidence files are checked before preview and export. This is a consistency check, not a cryptographic attestation by a third party.
- Unreferenced extra files are not exported. If the process crashes before the index is committed, unreferenced files may remain; they are not adopted as findings automatically.
- A stored start time without a session end can point to an aborted run. Reopening does not silently resume such a session.

## Static analysis

Local SDK tools: AAPT2 for badging and permissions, `apkanalyzer manifest print` for the XML and `apkanalyzer dex packages --defined-only` for classes and methods. This needs the SDK command-line tools and a working local Java runtime. No network or cloud API is used. The manifest is parsed without DTDs or external entity resolution.

Recorded are package, version and SDK levels, application attributes, activities and aliases, services, receivers, providers, explicit `exported`/`enabled` values, component permissions declared or inherited from the application element, and intent actions, categories and data attributes. Not every Android inheritance and runtime rule is evaluated; the complete XML and the declared coverage remain authoritative.

If the DEX inventory fails, the manifest analysis stays usable and the failure is recorded as a limitation. Tool output is limited to 4 MiB; a truncated DEX inventory is marked, and the app profile says so. Text previews show at most 200,000 characters; the stored files stay complete within the tool limit.

### App profile

Libraries are detected from manifest components, native libraries (`lib/*/*.so`), library markers (`*.properties`, `META-INF/*.version`) and, where available, the DEX inventory. The profile shows what is included, not whether or how it is used at runtime. Permissions are grouped by topic and labelled with Android's protection level: needs approval, special access, no prompt, system apps only, vendor, or app-internal.

REA/JADX decompilation, references, Frida Java probes and PCAP capture or import are described in [Code and data flow analysis](deep-analysis.md). New evidence kinds raise a project to schema 2; schema 1 projects stay readable. JNI/native decompilation, automatic vulnerability scans and complete network coverage are not included.

References: [APK Analyzer CLI](https://developer.android.com/tools/apkanalyzer), [App manifest overview](https://developer.android.com/guide/topics/manifest/manifest-intro), [Intents and intent filters](https://developer.android.com/guide/components/intents-filters).

## Reproducible check

```sh
CLANG_MODULE_CACHE_PATH="$TMPDIR/android-analyxer-clang-cache" swift test --disable-sandbox
swift run --disable-sandbox android-analyxer-cli project-create \
  .local/fixture/android-analyxer-fixture.apk .local/my-analysis.androidlab
swift run --disable-sandbox android-analyxer-cli project-info .local/my-analysis.androidlab
# Only on an explicitly chosen, disposable test emulator:
swift run --disable-sandbox android-analyxer-cli project-smoke emulator-5580 \
  .local/fixture/android-analyxer-fixture.apk .local/new-project-test.androidlab
```

`project-smoke` accepts only the synthetic fixture package and an emulator serial. It checks installation, launch, navigation, logs, screenshot, note, session end, reopening and the export round trip through the same core APIs as the interface.

## Importing from a Google Play device

**Installed Apps → Investigate …** copies the complete APK list Android reports, secures it with SHA-256 and checks that package paths and boot ID did not change. Package and version of the splits must match the base. The import contains no private app data. Source, Android's installer information and the installed paths are kept in the schema 3 project; the installer information says nothing about purchase rights or store availability.

**Adopt Installed App** then compares all installed APK hashes with the project and records a verification instead of pretending an installation. After reopening, start a new test session and adopt again. **Install APKs** installs the whole set with `install-multiple`, for example on a suitable analysis device. A store update or an on-demand feature can invalidate the match: import again.

The static main report and the component overview describe the base APK. REA can examine each contained APK separately. Exports contain all APKs and verify their integrity. Schemas 1 and 2 stay readable; additional REA findings do not downgrade schema 3.
