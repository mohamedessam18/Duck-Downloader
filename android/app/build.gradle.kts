import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Opt-out for offline release builds; see the crashlytics block below.
val uploadNativeSymbols =
    (project.findProperty("crashlytics.uploadNativeSymbols") as String?)
        ?.toBooleanStrictOrNull() ?: true

val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

android {
    namespace = "com.example.duck_downloader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.duck.downloader"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["adMobAppId"] =
            project.findProperty("adMobAppId") as String? ?: "ca-app-pub-3940256099942544~3347511713"
    }

    // A release config is only worth declaring when every value is actually
    // present. Declaring it unconditionally used to hand AGP a null storeFile,
    // which fails deep inside the signing task with an error that says nothing
    // about the missing android/key.properties that caused it.
    val hasReleaseSigning = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
        .all { !keyProperties.getProperty(it).isNullOrBlank() }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // Falls back to the debug key so a local release build still
                // runs. Play rejects debug-signed uploads outright, so this
                // cannot reach production by accident — but it must be loud,
                // because an unnoticed fallback looks exactly like success.
                logger.warn(
                    "\n" + "=".repeat(78) + "\n" +
                        "WARNING: android/key.properties not found — signing this " +
                        "release with the DEBUG key.\nThe resulting artifact CANNOT be " +
                        "uploaded to Google Play. Create android/key.properties from\n" +
                        "key.properties.example and point it at your upload keystore.\n" +
                        "=".repeat(78) + "\n"
                )
                signingConfigs.getByName("debug")
            }

            // R8: strips unused code and resources, and obfuscates what is
            // left. Reflection- and JNI-reached classes are pinned in
            // proguard-rules.pro; without those the build succeeds and then
            // fails at runtime.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )

            // Symbolicates the native crashes captured by firebase-crashlytics-ndk
            // below. Without it a SIGSEGV in ffmpeg or the Flutter engine arrives
            // as raw hex addresses, which is unreadable and therefore unfixable.
            //
            // This makes `bundleRelease` depend on an upload task, so it needs
            // network. Set `crashlytics.uploadNativeSymbols=false` in
            // gradle.properties (or `-P` on the command line) to build offline.
            configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
                nativeSymbolUploadEnabled = uploadNativeSymbols
            }
        }
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Catches native crashes — SIGSEGV/SIGABRT out of ffmpeg_kit, rive_native,
    // the video decoders and the Flutter engine itself. The Dart-side handlers
    // never see these: the process is already gone. Unversioned on purpose, so
    // the firebase_core BoM pins it alongside every other Firebase artifact.
    implementation("com.google.firebase:firebase-crashlytics-ndk")

    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
}
