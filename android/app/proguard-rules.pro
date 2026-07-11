-keep class com.stivaros.app.** { *; }
-keepclassmembers class com.stivaros.app.** { *; }
-keep class org.json.** { *; }

# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# Keep xray binary path
-keep class com.stivaros.app.XrayManager { *; }
