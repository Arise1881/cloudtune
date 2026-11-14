package com.cloudtune.app

import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // "Direkt cihaza kaydet": indirilen sesi MediaStore'a yazar; Android
        // 10+ RELATIVE_PATH ile Download/CloudTune klasöründe görünür olur.
        // Eski API'lerde izin yoksa sessizce atlanır (uygulama kendi saklar).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "melody/saver")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveAudioToLibrary" -> {
                        val src = call.argument<String>("path")
                        val title = call.argument<String>("title") ?: "melody"
                        val artist = call.argument<String>("artist") ?: ""
                        try {
                            val f = File(src ?: "")
                            if (!f.exists()) {
                                result.error("not_found", "İndirilen dosya bulunamadı", null)
                                return@setMethodCallHandler
                            }
                            val safe = title
                                .replace(Regex("[^\\p{L}\\p{N}_ -]"), "")
                                .trim()
                                .ifEmpty { "melody" }
                            val fileName = "$safe.m4a"
                            val values = ContentValues().apply {
                                put(MediaStore.Audio.Media.DISPLAY_NAME, fileName)
                                put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4")
                                put(MediaStore.Audio.Media.TITLE, title)
                                put(MediaStore.Audio.Media.ARTIST, artist)
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                    put(MediaStore.Audio.Media.RELATIVE_PATH, "Download/CloudTune")
                                    put(MediaStore.Audio.Media.IS_PENDING, 1)
                                }
                            }
                            val resolver = contentResolver
                            val uri = resolver.insert(
                                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values
                            )
                            if (uri == null) {
                                result.error("insert_failed", "MediaStore eklenemedi", null)
                                return@setMethodCallHandler
                            }
                            resolver.openOutputStream(uri)?.use { out ->
                                f.inputStream().use { it.copyTo(out) }
                            } ?: run {
                                resolver.delete(uri, null, null)
                                result.error("stream_failed", "Dosya akışı açılamadı", null)
                                return@setMethodCallHandler
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                values.clear()
                                values.put(MediaStore.Audio.Media.IS_PENDING, 0)
                                resolver.update(uri, values, null, null)
                            }
                            result.success("Download/CloudTune/$fileName")
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}