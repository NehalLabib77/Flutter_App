# R8 / ProGuard rules for the EduCompass Android release build.
#
# Flutter wraps Dart code in a single engine binary so the Java/Kotlin
# surface is small (Application + MainActivity + Flutter plugins).
# Keeping this file minimal preserves the work R8 already does
# (shrinking, optimisation, resource shrinking) without removing
# reflection-only entry points the plugins depend on.

# ---------------------------------------------------------------------------
# Flutter engine
# ---------------------------------------------------------------------------

# io.flutter.embedding.* is referenced reflectively by the Flutter
# engine when starting up; the default proguard-android-optimize.txt
# already keeps most of it, but be explicit so a future R8 bump
# doesn't strip a needed entry point.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.util.** { *; }

# ---------------------------------------------------------------------------
# Plugins used by the app
# ---------------------------------------------------------------------------

# shared_preferences uses MethodChannel + a SharedPreferences plugin
# implementation that some plugin versions resolve via Class.forName.
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# url_launcher resolves activity classes via PackageManager queries;
# its plugin internals reflectively find IntentFilter handlers.
-keep class io.flutter.plugins.urllauncher.** { *; }

# cached_network_image is pure Dart (no Java reflection) but the
# image cache disk-path uses Android Environment.getExternalStorage
# paths via the Flutter plugin registrar — keep its registrar class.
-keep class com.bumptech.glide.** { *; }
-dontwarn com.bumptech.glide.**

# ---------------------------------------------------------------------------
# Firebase (used by EnrollmentService for Firestore + Auth)
# ---------------------------------------------------------------------------

# Firebase Android SDK relies on reflection for plugin loading and
# for some analytics hooks. The FlutterFire team publishes rules
# that are pulled in transitively by the firebase_* plugin AARs,
# but adding the canonical block here is harmless and acts as a
# safety net if a future upgrade drops the bundled rules.
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Google Play Services tasks (used by gms.google-services plugin).
-keep class com.google.android.gms.tasks.** { *; }
-keepclassmembers class * {
    @com.google.android.gms.tasks.OnCompleteListener <methods>;
}

# ---------------------------------------------------------------------------
# Kotlin / Coroutines
# ---------------------------------------------------------------------------

# Kotlin reflection metadata used by the Flutter Android embedding.
-keep class kotlin.Metadata { *; }
-keepattributes *Annotation*, InnerClasses, Signature, EnclosingMethod

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# Suppress warnings for missing optional classes from R8.
-dontwarn javax.annotation.**
-dontwarn org.codehaus.mojo.animal_sniffer.IgnoreJRERequirement

# ---------------------------------------------------------------------------
# Google Play Core (deferred components — used optionally by Flutter embedding)
# ---------------------------------------------------------------------------
# The Flutter engine ships references to Play Core's SplitInstall API for
# deferred-component support, but the classes are only present at runtime if
# the app actually uses dynamic features. EduCompass does not, so we tell
# R8 not to warn (and not to require them) when shrinking the release APK.
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
