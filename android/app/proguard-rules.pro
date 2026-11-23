# Flutter framework + generated plugin registrator (yansıma ile bulunur).
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class !io.flutter.embedding.engine.deferredcomponents.**,!io.flutter.embedding.android.FlutterPlayStoreSplitApplication,io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class **.GeneratedPluginRegistrant { *; }

# Dart entrypoint ve uygulama aktivitesi JNI üzerinden çağrılır.
-keep class com.cloudtune.app.MainActivity { *; }

# flutter_whisper_ggml / just_audio / media_kit native metodları JNI ile
# çağrılır; isimeri ire R8 değiştirmemeli.
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class com.flutterwhisper.** { *; }
-keep class **.FlutterWhisper** { *; }

# mqtt_client ve audio_service olay dinleyicileri reflection ile kurulur.
-keep class org.eclipse.paho.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.rd.liquorice.** { *; }

# Flutter engine embedding ve Dart VM giriş noktaları.
-keep class !io.flutter.embedding.engine.deferredcomponents.**,!io.flutter.embedding.android.FlutterPlayStoreSplitApplication,io.flutter.embedding.** { *; }
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes SourceFile,LineNumberTable

# Uyarıları bastır; kütüphane içi eksik sınıflar derlemeyi durdurmasın.
-dontwarn io.flutter.**
-dontwarn com.ryanheise.**
-dontwarn org.eclipse.paho.**
