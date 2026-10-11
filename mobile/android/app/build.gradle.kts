import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (DEPLOYMENT.md §5.1). The upload key is described by android/key.properties,
// which is gitignored and never committed. When it is absent (local machines, CI compile
// checks) release builds fall back to the debug key so `flutter build apk --release` still
// works; such builds can never be uploaded to Play.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun keystoreProperty(name: String): String =
    keystoreProperties.getProperty(name)
        ?: throw GradleException("android/key.properties is missing '$name'")

android {
    // PROVISIONAL until product decision D1 (domain / application ID). The application ID
    // cannot change after the first Play upload. See mobile/README.md.
    namespace = "app.afterme"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications (foreground notifications, Phase 8) is built with core
        // library desugaring, and the app module must agree or the AAR metadata check
        // fails the build. minSdk 26 already has java.time; this changes nothing at runtime.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "app.afterme"
        // PLAY_STORE.md §3: min SDK 26 (Android 8.0), target SDK 36 (Android 16).
        minSdk = 26
        targetSdk = 36
        // versionCode/versionName come from pubspec.yaml (`version: x.y.z+build`).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildFeatures {
        resValues = true
    }

    flavorDimensions += "env"
    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "AfterMe Dev")
        }
        create("staging") {
            dimension = "env"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            resValue("string", "app_name", "AfterMe Staging")
        }
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "AfterMe")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperty("keyAlias")
                keyPassword = keystoreProperty("keyPassword")
                storeFile = rootProject.file(keystoreProperty("storeFile"))
                storePassword = keystoreProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Code and resource shrinking (R8) are part of the release, stated here and
            // not left to the Flutter Gradle plugin's default (Phase 9 review M-04).
            // The plugin also adds proguard-android-optimize.txt, its own
            // flutter_proguard_rules.pro and android/app/proguard-rules.pro (this app's,
            // next to this file); the libraries ship their consumer rules. Release builds
            // are made with tool/build_release.sh, which adds --obfuscate and
            // --split-debug-info and runs the manifest check.
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    logger.warn(
                        "AfterMe: android/key.properties not found; release build is signed " +
                            "with the DEBUG key (local use only, never upload).",
                    )
                    signingConfigs.getByName("debug")
                }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Required by isCoreLibraryDesugaringEnabled above (flutter_local_notifications 22).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
