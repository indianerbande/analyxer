#!/bin/bash
# Add a resource-only split to the existing synthetic fixture (same signing key).
set -euo pipefail
cd "$(dirname "$0")/.."
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
build_tools="$sdk_root/build-tools/${FIXTURE_BUILD_TOOLS:-37.0.0}"
export JAVA_HOME="${FIXTURE_JAVA_HOME:-$(/usr/libexec/java_home)}"
fixture_output="$PWD/.local/fixture"
[[ -f "$fixture_output/android-analyxer-fixture.apk" ]] || scripts/build-fixture.sh
split_work="$(mktemp -d "$fixture_output/split.XXXXXX")"
trap 'rm -rf "$split_work"' EXIT
cat > "$split_work/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="lab.androidanalyxer.fixture" split="config.lab" android:versionCode="1" android:versionName="1.0">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="34"/>
  <application android:hasCode="false"/>
</manifest>
XML
android_jar="${FIXTURE_ANDROID_JAR:-}"
if [[ -z "$android_jar" ]]; then
    for platform in 34 35 36 36.1 37.0; do
        candidate="$sdk_root/platforms/android-$platform/android.jar"
        if [[ -f "$candidate" ]]; then android_jar="$candidate"; break; fi
    done
fi
"$build_tools/aapt2" link -I "$android_jar" --manifest "$split_work/AndroidManifest.xml" -o "$split_work/unsigned.apk"
"$build_tools/zipalign" -f 4 "$split_work/unsigned.apk" "$split_work/aligned.apk"
"$build_tools/apksigner" sign --ks "$fixture_output/debug.keystore" --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out "$fixture_output/fixture-split.apk" "$split_work/aligned.apk"
"$build_tools/apksigner" verify "$fixture_output/fixture-split.apk"
echo "$fixture_output/fixture-split.apk"
