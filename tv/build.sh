#!/usr/bin/env bash
# Build the wireless-display receiver APK with plain SDK tools (no Gradle, no libraries).
#   ./build.sh            build build/tv-screen.apk
#   TV=192.168.1.20 ./build.sh install    build, install on the TV (over adb) and launch it
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/35.0.0"
JAR="$SDK/platforms/android-34/android.jar"
PKG=app.tvscreen

rm -rf build && mkdir -p build/gen build/classes build/dex

"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml --java build/gen \
  --min-sdk-version 28 --target-sdk-version 34 --version-code 3 --version-name 1.1.1 \
  -o build/unsigned.apk build/res.zip

javac -nowarn --release 11 -classpath "$JAR" -d build/classes \
  $(find src build/gen -name '*.java')
"$BT/d8" --release --min-api 28 --lib "$JAR" --output build/dex \
  $(find build/classes -name '*.class')
(cd build/dex && zip -q -j ../unsigned.apk classes.dex)

[ -f signing.keystore ] || keytool -genkeypair -keystore signing.keystore -storepass android \
  -keypass android -alias home -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=TV Display" >/dev/null 2>&1
"$BT/zipalign" -f 4 build/unsigned.apk build/aligned.apk
"$BT/apksigner" sign --ks signing.keystore --ks-pass pass:android --ks-key-alias home \
  --out build/tv-screen.apk build/aligned.apk
echo "Built build/tv-screen.apk ($(du -k build/tv-screen.apk | cut -f1) KB)"

if [ "${1:-}" = "install" ]; then
  TV="${TV:?set TV to the IP address shown on the TV, e.g. TV=192.168.1.20 ./build.sh install}"
  case "$TV" in *:*) ;; *) TV="$TV:5555" ;; esac
  adb connect "$TV" >/dev/null
  adb -s "$TV" install -r build/tv-screen.apk
  adb -s "$TV" shell am start -n "$PKG/.MainActivity"
fi
