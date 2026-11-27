# Noir Player's changes to on_audio_query_android

This is [on_audio_query_android](https://pub.dev/packages/on_audio_query_android) 1.1.0
from pub.dev (the `example/` and `test/` folders left out), under its original
BSD 3-Clause licence (see `LICENSE`). Only the Android build setup changed. No Kotlin
source was touched and the Dart API is the same.

The 1.1.0 release is unmaintained and its build file dates from AGP 4.1 / Kotlin 1.6.
It applied the Kotlin Gradle Plugin (`kotlin-android`), which makes Flutter 3.50 print
"plugins that apply Kotlin Gradle Plugin (KGP)" and will fail builds in a later Flutter.

- `android/build.gradle` and `android/settings.gradle` replaced by `android/build.gradle.kts`,
  following Flutter's plugin template: `namespace`, compileSdk 36, minSdk 24, Java 17,
  and `kotlin { compilerOptions { jvmTarget } }`. No `kotlin-android` plugin is declared,
  which is what the Flutter guide for built-in Kotlin prescribes
  (https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors).
  With `android.builtInKotlin=false` in the app, Flutter's Gradle plugin applies
  `kotlin-android` to such modules itself (`detectApplyingKotlinGradlePlugin`), and with
  `true` AGP's built-in Kotlin takes over. Either way the module itself no longer applies KGP.
- Coroutines 1.10.2 and lifecycle-viewmodel-ktx 2.8.7 (were 1.6.4 / 2.3.1).
- `AndroidManifest.xml`: `package=` dropped (now the `namespace`).
- `pubspec.yaml`: minimum raised to Flutter 3.44 / Dart 3.12 (as the guide asks).
- Gradle wrapper, `gradle.properties` removed (unused when built as a plugin).

To update: if a maintained release adds built-in Kotlin support, drop this folder and the
`dependency_overrides` entry in the app's `pubspec.yaml`.
