# Built client

`craft.apk` is the Android build, kept here because a repository is a place
people can already reach. It is rebuilt by hand, not by anything automatic, so
the commit it came from is the commit that added it.

| | |
|---|---|
| Size | 3.4 MB |
| SHA-256 | `6e508478b968d631a08b5cdd90dca8ec3e1717b76f215816f7c61727f0c51276` |
| Signing certificate | `4bc67728ff174b924671b3c0c20c2dc7e549a79e2546b2db41870ab99ad9db02` |
| Android | 5.0 and up (API 21) |
| Graphics | OpenGL ES 2.0 |
| ABIs | armeabi-v7a, arm64-v8a, x86, x86_64 |

The minimum is not what the engine needs -- it would run on far less -- but as
far back as a current NDK will build. An older NDK moves it: r24 reaches
Android 4.4, r22 reaches 4.1, and neither of the build scripts changes.

## Installing it

It is signed with a key generated on the machine that built it, not by any
store, so a phone will ask before installing and that is the expected answer to
give. Copy it across and open it, or over a cable:

```sh
adb install -r craft.apk
```

The signing certificate above is what an update has to match: an APK built on a
different machine carries a different key and will refuse to install over this
one until the old copy is removed.

## Building it again

```sh
tools/android-build.sh /path/to/android-ndk      # one stripped library per ABI
tools/android-apk.sh   /path/to/android-sdk      # packs and signs
```

Neither needs Android Studio. What they do need is the NDK, and the SDK's
build-tools and one platform, which together are about 900 MB.
