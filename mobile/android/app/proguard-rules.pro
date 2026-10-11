# AfterMe release shrinking rules (R8). Picked up by the Flutter Gradle plugin by name,
# on top of proguard-android-optimize.txt and Flutter's own flutter_proguard_rules.pro.
#
# Nothing has to be kept by hand today: Firebase Messaging, androidx.biometric (local_auth),
# Tink (flutter_secure_storage) and Gson (flutter_local_notifications 19+) ship their own
# consumer rules, and the app's native code (MainActivity) is reached from the manifest and
# from Flutter's method channels, never by reflection. A release build whose R8 step reports
# missing classes names the rule to add here; add it with the reason.
#
# Keep line numbers and a neutral source file name so a native stack trace can be retraced
# with the build's mapping.txt (build/app/outputs/mapping/prodRelease/). Names stay
# obfuscated. Keep that file as private as the Dart symbols (--split-debug-info).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
