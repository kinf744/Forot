-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keepattributes EnclosingMethod

# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.app.** { *; }

# Kotlin
-keep class kotlin.** { *; }
-dontwarn kotlin.**

# AndroidX
-keep class androidx.** { *; }
-keep interface androidx.** { *; }
-dontwarn androidx.**

# Gson
-keep class com.google.gson.** { *; }
-keepattributes Signature

# Our app
-keep class com.stivaros.app.** { *; }

# Provider
-dontwarn com.google.errorprone.annotations.**

# Keep all native methods
-keepclasseswithmembernames class * {
    native <methods>;
}
