#!/usr/bin/env bash
#
# Packs the libraries built by android-build.sh into an installable APK.
#
# There is no Android Studio here and none is needed: an APK is a zip with a
# compiled manifest, and the three tools that make one (aapt2, zipalign,
# apksigner) ship in the SDK's build-tools on their own.
#
#   tools/android-apk.sh <sdk root> [output.apk]
#
# The sdk root is expected to hold a build-tools directory with aapt2 in it and
# a platform directory with android.jar. Signing uses a key kept next to the
# build: an APK has to be signed to install at all, and a self signed one is
# what sideloading wants.

set -euo pipefail

sdk=${1:?usage: android-apk.sh <sdk root> [out.apk]}
out=${2:-zig-out/android/craft.apk}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

aapt2=$(find "$sdk" -maxdepth 3 -name aapt2 -type f | head -1)
zipalign=$(find "$sdk" -maxdepth 3 -name zipalign -type f | head -1)
apksigner=$(find "$sdk" -maxdepth 3 -name apksigner -type f | head -1)
android_jar=$(find "$sdk" -maxdepth 3 -name android.jar -type f | head -1)

for tool in "$aapt2" "$zipalign" "$apksigner" "$android_jar"; do
    [ -n "$tool" ] || { echo "Missing a build tool under $sdk" >&2; exit 1; }
done

work=zig-out/android/apk
rm -rf "$work"
mkdir -p "$work"

# 1. The resources: an icon at every density, compiled into aapt2's own format
"$aapt2" compile --dir android/res -o "$work/res.zip"

# 2. The manifest and the resource table, which is the APK's skeleton
"$aapt2" link \
    -o "$work/base.apk" \
    -I "$android_jar" \
    --manifest android/AndroidManifest.xml \
    --min-sdk-version 21 \
    --target-sdk-version 34 \
    "$work/res.zip"

# 3. Everything the zip carries as it is: the libraries under lib/<abi>, and
#    the game's files under assets, where raylib's asset manager looks for them
mkdir -p "$work/stage/assets"
for abi_dir in zig-out/android/*/lib/libmaincraft.so; do
    [ -e "$abi_dir" ] || continue
    abi=$(basename "$(dirname "$(dirname "$abi_dir")")")
    mkdir -p "$work/stage/lib/$abi"
    cp "$abi_dir" "$work/stage/lib/$abi/"
done

# The client asks for "res/shaders/chunk.vs" and the like, so the tree keeps its
# shape inside assets
cp -r res "$work/stage/assets/res"
rm -rf "$work/stage/assets/res/jar"

cp "$work/base.apk" "$work/unaligned.apk"
(cd "$work/stage" && zip -q -r -X "../unaligned.apk" lib assets)

# 4. Align, then sign. In that order: signing covers the file as it will be read
"$zipalign" -f -p 4 "$work/unaligned.apk" "$work/aligned.apk"

keystore=android/debug.keystore
if [ ! -f "$keystore" ]; then
    echo "=== making a signing key"
    keytool -genkeypair -v \
        -keystore "$keystore" \
        -alias craft \
        -keyalg RSA -keysize 2048 -validity 10950 \
        -storepass craftzig -keypass craftzig \
        -dname "CN=Craft.zig, OU=None, O=None, L=None, S=None, C=None" > /dev/null
fi

mkdir -p "$(dirname "$out")"
"$apksigner" sign \
    --ks "$keystore" --ks-pass pass:craftzig --key-pass pass:craftzig \
    --v1-signing-enabled true --v2-signing-enabled true \
    --out "$out" "$work/aligned.apk"

"$apksigner" verify --print-certs "$out" | head -3
echo
ls -la "$out"
unzip -l "$out" | tail -5
