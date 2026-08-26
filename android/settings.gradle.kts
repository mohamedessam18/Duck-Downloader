pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    // Reads android/app/google-services.json into the build.
    id("com.google.gms.google-services") version "4.4.3" apply false
    // Uploads the R8 mapping file so Crashlytics can deobfuscate stack traces.
    // Without it every release crash report is unreadable symbol soup.
    id("com.google.firebase.crashlytics") version "3.0.6" apply false
}

include(":app")
