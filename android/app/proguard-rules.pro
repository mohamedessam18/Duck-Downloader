# R8 keep rules for the release build.
#
# Most plugins ship their own consumer rules, which AGP merges in automatically.
# What is listed here is only what R8 cannot infer on its own: classes reached
# through reflection or from native code, where there is no bytecode reference
# for the shrinker to follow.

# ---------------------------------------------------------------------------
# Flutter engine
# ---------------------------------------------------------------------------
# The embedding is instantiated by name from the manifest's ${applicationName}.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ---------------------------------------------------------------------------
# ffmpeg_kit_flutter_new
# ---------------------------------------------------------------------------
# The native layer calls back into these across JNI. Renaming them compiles
# fine and then fails at runtime the first time a trim/convert job runs, with
# an UnsatisfiedLinkError that points nowhere useful.
-keep class com.arthenica.ffmpegkit.** { *; }
-keep class com.arthenica.smartexception.** { *; }
-dontwarn com.arthenica.**

# ---------------------------------------------------------------------------
# rive_native
# ---------------------------------------------------------------------------
# Same JNI story as ffmpeg: the Rive renderer resolves Java symbols by name.
-keep class app.rive.** { *; }
-dontwarn app.rive.**

# ---------------------------------------------------------------------------
# flutter_inappwebview
# ---------------------------------------------------------------------------
# @JavascriptInterface methods are looked up by name from the WebView bridge.
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# ---------------------------------------------------------------------------
# audio_service / just_audio_background
# ---------------------------------------------------------------------------
# Declared in the manifest, so R8 keeps the classes themselves, but the media
# session callbacks are dispatched reflectively by the support library.
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }
-keep class androidx.media.** { *; }
-keep class android.support.v4.media.** { *; }

# ---------------------------------------------------------------------------
# Play Billing (in_app_purchase)
# ---------------------------------------------------------------------------
# Purchase payloads are deserialized reflectively; a renamed field silently
# turns every restore into "no purchases found".
-keep class com.android.vending.billing.** { *; }
-keep class com.android.billingclient.api.** { *; }

# ---------------------------------------------------------------------------
# Google Mobile Ads
# ---------------------------------------------------------------------------
-keep class com.google.android.gms.ads.** { *; }
-keep class com.google.android.gms.internal.ads.** { *; }
-dontwarn com.google.android.gms.**

# ---------------------------------------------------------------------------
# local_auth / androidx.biometric
# ---------------------------------------------------------------------------
-keep class androidx.biometric.** { *; }
-keep class androidx.fragment.app.** { *; }

# ---------------------------------------------------------------------------
# This app's own platform channel surface
# ---------------------------------------------------------------------------
# MainActivity is named in the manifest, but the PiP/media helpers it exposes
# are only ever reached from Dart over a MethodChannel — no Java caller for R8
# to trace.
-keep class com.example.duck_downloader.** { *; }

# ---------------------------------------------------------------------------
# Firebase Crashlytics / Analytics
# ---------------------------------------------------------------------------
# SourceFile and LineNumberTable are kept below; the Crashlytics Gradle plugin
# uploads the mapping file so the obfuscated names are resolved server-side.
# Custom exception class names must survive, otherwise every crash in the
# dashboard is grouped under a single meaningless obfuscated name.
-keep public class * extends java.lang.Exception
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------
# Keep annotations and generic signatures so reflection-based deserialization
# in any of the above keeps working.
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod
-keepattributes SourceFile, LineNumberTable

# Parcelable CREATOR fields are read reflectively by the framework.
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# Enum valueOf/values are used by reflection in several plugins.
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Suppress warnings for optional dependencies that are never on the runtime
# classpath (Play Core split-install, javax annotations pulled in transitively).
-dontwarn com.google.android.play.core.**
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
