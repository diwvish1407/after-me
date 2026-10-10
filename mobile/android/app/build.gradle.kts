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

flutter {
    source = "../.."
}
