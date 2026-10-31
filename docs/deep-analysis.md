# Code and data flow analysis

[Deutsch](de/deep-analysis.md)

## Concept

An APK is kept unchanged as the project's source. REA/JADX examines this source and returns classes, methods, decompiled code and incoming static references. From these you choose concrete probes for the running app: for example a method that builds a request, or one that processes a response that is already decrypted.

Runtime observation runs through REA/Frida. It records the arguments, return values and exception types of selected methods. The original method still runs; return values and exceptions are passed on. Instrumentation can still affect timing and runtime behaviour. Network captures add visible peers, ports and packet counts to the process observation; they do not decrypt TLS payloads. Code findings, process events and network traffic are different kinds of evidence, not an automatically proven chain of cause and effect.

In a project this is the section **2 · Examine Code and Data Flows**. All results are stored in the analysis project together with the APK hash, session, timestamps, device metadata, the unchanged REA evidence files and the observation script that was actually used.

## Local tools

Tested with REA 6.5.0, Node 24.15.0, JADX headless MCP 0.7.1, a full JDK 25, Frida 17.23.2 and frida-java-bridge 7.0.13; the tool manager installs REA 6.8.0 and Node 24.22.2. The JVM is limited to 1 GiB by default. **Setup → Analysis Tools** checks and installs these tools and sets the tool profile; see [Setup and tools](setup.md). **Load Tool Profile …** in the project section accepts a JSON profile instead.

The JADX JAR comes from the official release that REA references (SHA-256 for 0.7.1: `6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75`). `scripts/instrumentation/build-java-bridge.mjs` builds the Java bridge from an explicitly chosen local frida-java-bridge installation with Frida's compiler; the tool manager does the same automatically.

## Examining an APK

1. Open the project; the tool profile must be ready.
2. Use **Inspect APK with REA** for package and manifest findings, or **Find Classes**.
3. Take a fully qualified class name and choose **List Methods**.
4. Enter the method name and, if needed, the overload index from the list; choose **Decompile** or **References**. Overload indices start at zero.

REA always analyses the verified project copy. Its answer must match the operation and the APK's SHA-256. Tool errors are stored as error findings. The preview presents the normalised finding readably; the original JSON with evidence ID, provider and limits is kept. The analysis never runs the APK. Incoming static references do not prove that a call happens at runtime.

## Observing data in the process

This needs a prepared analysis device with a matching frida-server running on guest port 27042. The identity check also needs readable `/proc/<PID>/cmdline` and `/proc/<PID>/stat`; on the tested Google APIs image adbd runs as root for that. A root frida-server alone does not guarantee these ADB permissions. The app does not enable root, does not start frida-server and does not change certificates. Regular Google Play images are not suitable without further preparation; everyday use of them is a separate device mode.

1. Start a test session, install the project APK and launch it.
2. Enter the class and method from the code analysis.
3. Enter the exact Java argument types, separated by commas, for example `java.lang.String` or `[B`; empty means no parameters. The static overload index is not used here: what counts is the actual list of Java types.
4. Choose the duration and press **Observe Method**. Use the app in the Android window while it records.
5. Open the process finding and the recording context in the evidence list.

Before recording, the installed APKs are pulled over ADB and checked against the project's complete APK set. Imported base/split sets are supported; a single base APK cannot vouch for a split installation. Static REA queries refer to the APK chosen in the picker. The target is the app's unique main process. Boot ID, process name and process start time bind the recording; a device change, a restart or a reused PID causes an error. The dynamic ADB port forward is removed after recording; Frida detaches and the app keeps running.

The interface offers one probe per recording; the core API supports up to eight. Primitive values, strings and byte arrays are recorded; other objects stay opaque. No streams are read and no arbitrary object methods are called for display. Defaults: 200 calls and 4,096 characters per value, at most 60 seconds. Limits and truncated values are marked. Calls already running or finished before the hook was installed are missing. No observed call only means that no matching call was registered during the recording window.

This is targeted Java observation, not automatic capture of every HTTP library, JNI/native function or secondary process. Reflection, dynamic class loaders, native TLS stacks and additional content encryption may need other probes or further adapters. Certificate pinning is not changed.

## Network capture

**Record Mobile/WAN** uses the SDK emulator console. With emulator 37.1.11 it captures the legacy WAN/cellular path, not the modern netsim Wi-Fi. It replaces a console capture that is already running. The app does not change guest network settings. Recording lasts at most 60 seconds; up to 32 MiB are kept. If the limit is exceeded, the recording is stopped and discarded.

**Import PCAP …** takes external classic PCAP files of up to 32 MiB. Their origin, capture device and relation to the active session stay explicitly unverified. PCAPNG is not supported. The built-in parser shows the packet count, visible IPv4/IPv6 endpoints and TCP/UDP ports. It supports Ethernet/VLAN, Linux cooked v1/v2 and raw IP; fragmented packets and IPv6 extension headers are evaluated only partly. It does not reconstruct TCP streams, DNS names, HTTP bodies or TLS plaintext.

Device traffic can include Android, Google services and other apps. Closeness in time to an action does not prove which app caused it. The complete PCAP is exported with its hash and can be examined further in a suitable external tool. REA's Linux/Windows PCAP provider is not assumed on macOS.

## Reproducible local HTTPS test

`scripts/build-fixture.sh` builds the synthetic APK and a local test certificate with the IP SAN `10.0.2.2`. The private test key stays under `.local/tls`. The fixture trusts only this certificate for its fixed local test endpoint; hostname verification stays on. A normal start makes no network calls. Only the explicit intent extra `run_tls=true` starts eight synthetic HTTPS exchanges.

```sh
scripts/build-fixture.sh
python3 scripts/fixture-tls-server.py
# In a second terminal, with a prepared, isolated test emulator:
swift run --disable-sandbox analyxer-cli analysis-smoke emulator-5580 \
  .local/fixture/analyxer-fixture.apk .local/new-analysis-test.androidlab \
  .local/analysis-tools.json
```

The server binds only `127.0.0.1:18443`. The test accepts only the fixture package. It decompiles `buildRequest(String)`, installs the verified APK and observes `buildRequest` and `consumeResponse` during real local TLS traffic. It then checks plaintext markers and the export round trip. No external service and no private APKs are needed.

References: [REA](https://github.com/morluto/rea), [Frida on Android](https://frida.re/docs/android/), [Frida JavaScript API](https://frida.re/docs/javascript-api/), [Android Emulator console](https://developer.android.com/studio/run/emulator-console), [Advanced emulator networking](https://developer.android.com/studio/run/emulator-networking-advanced).
