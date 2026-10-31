#!/bin/bash
# Build a synthetic debug APK entirely from the existing local Android SDK.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
fixture_output="$project_root/.local/fixture"

if [[ -n "${FIXTURE_BUILD_TOOLS:-}" ]]; then
    build_tools="$sdk_root/build-tools/$FIXTURE_BUILD_TOOLS"
else
    tool_version="$(for tool_dir in "$sdk_root"/build-tools/*; do
        [[ -d "$tool_dir" ]] && basename "$tool_dir"
    done | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/' | sort -t . -k1,1n -k2,2n -k3,3n | tail -n 1)"
    build_tools="$sdk_root/build-tools/$tool_version"
fi

if [[ -n "${FIXTURE_ANDROID_JAR:-}" ]]; then
    android_jar="$FIXTURE_ANDROID_JAR"
else
    android_jar=""
    # Prefer the requested API 34; a newer compile SDK can still target API 34.
    for platform in 34 35 36 36.1 37.0; do
        candidate="$sdk_root/platforms/android-$platform/android.jar"
        if [[ -f "$candidate" ]]; then android_jar="$candidate"; break; fi
    done
fi

if [[ ! -f "$android_jar" ]]; then
    echo "No installed Android platform jar found. Set FIXTURE_ANDROID_JAR." >&2
    exit 1
fi
for tool in aapt2 d8 zipalign apksigner; do
    if [[ ! -x "$build_tools/$tool" ]]; then
        echo "Missing installed SDK tool: $build_tools/$tool" >&2
        exit 1
    fi
done

if [[ -n "${FIXTURE_JAVA_HOME:-}" ]]; then
    java_root="$FIXTURE_JAVA_HOME"
elif [[ -x /usr/libexec/java_home ]]; then
    java_root="$(/usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home)"
else
    java_root="${JAVA_HOME:?Set JAVA_HOME or FIXTURE_JAVA_HOME to an installed JDK}"
fi
export JAVA_HOME="$java_root"
for tool in javac keytool java; do
    if [[ ! -x "$java_root/bin/$tool" ]]; then
        echo "Missing JDK tool: $java_root/bin/$tool" >&2
        exit 1
    fi
done

mkdir -p "$fixture_output"
mkdir -p "$fixture_output/assets" "$project_root/.local/tls"
if [[ ! -f "$project_root/.local/tls/cert.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
        -keyout "$project_root/.local/tls/key.pem" -out "$project_root/.local/tls/cert.pem" \
        -subj '/CN=Android Analyxer Local Fixture' \
        -addext 'subjectAltName=IP:10.0.2.2,IP:127.0.0.1,DNS:localhost' >/dev/null 2>&1
    chmod 600 "$project_root/.local/tls/key.pem"
fi
cp "$project_root/.local/tls/cert.pem" "$fixture_output/assets/lab-cert.pem"
build_dir="$(mktemp -d "$fixture_output/build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
mkdir -p "$build_dir/classes" "$build_dir/dex"

"$java_root/bin/javac" -source 8 -target 8 -bootclasspath "$android_jar" \
    -d "$build_dir/classes" \
    "$project_root/fixture/src/lab/androidanalyxer/fixture/MainActivity.java"
"$build_tools/d8" --lib "$android_jar" --min-api 23 \
    --output "$build_dir/dex" \
    "$build_dir/classes/lab/androidanalyxer/fixture/"*.class
"$build_tools/aapt2" link -I "$android_jar" \
    -A "$fixture_output/assets" \
    --manifest "$project_root/fixture/AndroidManifest.xml" \
    -o "$build_dir/unsigned.apk"
/usr/bin/zip -q -X -j "$build_dir/unsigned.apk" "$build_dir/dex/classes.dex"
"$build_tools/zipalign" -f 4 "$build_dir/unsigned.apk" "$build_dir/aligned.apk"

keystore_path="$fixture_output/debug.keystore"
if [[ ! -f "$keystore_path" ]]; then
    "$java_root/bin/keytool" -genkeypair -noprompt \
        -keystore "$keystore_path" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Analyxer Fixture,OU=Local Development,O=Android Analyxer,C=DE"
fi
apk_path="$fixture_output/android-analyxer-fixture.apk"
"$build_tools/apksigner" sign --ks "$keystore_path" --ks-key-alias androiddebugkey \
    --ks-pass pass:android --key-pass pass:android \
    --out "$apk_path" "$build_dir/aligned.apk"
"$build_tools/apksigner" verify "$apk_path"
"$build_tools/zipalign" -c 4 "$apk_path"
echo "Built using $android_jar and build-tools $(basename "$build_tools")"
echo "$apk_path"
