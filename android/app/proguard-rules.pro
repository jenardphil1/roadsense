# Flutter engine & plugins
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.plugins.** { *; }

# TensorFlow Lite & GPU Delegate JNI
-keep class org.tensorflow.lite.** { *; }
-keepclassmembers class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# Flutter Vision native YOLO plugin
-keep class com.vladih.computer_vision.flutter_vision.** { *; }

# Firebase / Google Play Services
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# Additional plugins to prevent R8 stripping across varied OEM Android builds
-keep class com.baseflow.geolocator.** { *; }
-keep class com.hemanthraj.flutter_compass.** { *; }
-keep class com.tundralabs.fluttertts.** { *; }
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class io.flutter.plugins.camera.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class dev.fluttercommunity.plus.connectivity.** { *; }
