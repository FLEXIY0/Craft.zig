#!/usr/bin/env bash
#
# Builds the client's shared library for every Android ABI worth shipping.
#
# The ABI names are Android's, the target triples are zig's, and they do not
# match: this table is the whole of the translation. armeabi-v7a is the reason
# the list is not just arm64 -- it is what phones from before 2014 run, and it
# still boots on everything since.
#
#   tools/android-build.sh /path/to/android-ndk [api-level]
#
# Leaves each library in zig-out/android/<abi>/lib/libmaincraft.so

set -euo pipefail

ndk=${1:?usage: android-build.sh <ndk path> [api level]}
api=${2:-21}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Android ABI : zig target
#
# The two 32 bit entries are the point of the list. armeabi-v7a is what every
# Android phone older than about 2014 runs, and neither it nor x86 can do a 64
# bit atomic -- see engine/atomic64.zig, which is why they build at all.
abis=(
    "armeabi-v7a:arm-linux-androideabi"
    "arm64-v8a:aarch64-linux-android"
    "x86_64:x86_64-linux-android"
    "x86:x86-linux-android"
)

strip=$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
[ -x "$strip" ] || { echo "No llvm-strip in $ndk" >&2; exit 1; }

# A build that fails must not leave the previous library where the packaging
# step will find it: an APK quietly holding one stale ABI is a bug that only
# shows up on one kind of phone
rm -rf "$root/zig-out/android"

cd "$root"
for entry in "${abis[@]}"; do
    abi=${entry%%:*}
    triple=${entry##*:}

    echo "=== $abi ($triple)"
    # The pipe would swallow the exit status, and the linker's twenty lines of
    # noise about raylib's archive would bury a real error
    if ! zig build \
        -Dtarget="$triple" \
        -Doptimize=ReleaseFast \
        -Dandroid-ndk="$ndk" \
        -Dandroid-api="$api" \
        --prefix "zig-out/android/$abi" \
        > "/tmp/craft-android-$abi.log" 2>&1
    then
        grep -vE "is neither ET_REL|warning\(link\)" "/tmp/craft-android-$abi.log" >&2
        echo "$abi failed" >&2
        exit 1
    fi

    # A debug build of the engine is 3 MB of symbols nobody on a phone can use,
    # and there are four of these in the APK
    "$strip" "zig-out/android/$abi/lib/libmaincraft.so"
    ls -la "zig-out/android/$abi/lib/libmaincraft.so"
done
