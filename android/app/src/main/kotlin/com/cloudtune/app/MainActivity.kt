package com.cloudtune.app

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val notificationPermissionCode = 1001
    private val storagePermissionCode = 1002

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Android 13+ bildirim izni: kilit ekrani / medya bildirimi icin.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionCode
            )
        }

        // Android 9 ve altinda cihaza indirme icin depolama izni.
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                storagePermissionCode
            )
        }

        // "Dogrudan cihaza kaydet": indirilen sesi MediaStore'a yazar;
        // Android 10+ RELATIVE_PATH ile Download/CloudTune klasorunde gorunur.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cloudtune/saver")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveAudioToLibrary" -> {
                        val src = call.argument<String>("path")
                        val title = call.argument<String>("title") ?: "CloudTune"
                        val artist = call.argument<String>("artist") ?: ""
                        // Dart tarafı gerçek itag/MIME'ye göre uzantı ve tip
                        // gönderir; sabit .m4a her dosyayı bozuk gösteriyordu.
                        val extension = call.argument<String>("extension")
                            ?.takeIf { it.matches(Regex("\\.(webm|m4a|mp3)")) }
                            ?: ".m4a"
                        val mime = call.argument<String>("mime")
                            ?.takeIf { it.startsWith("audio/") }
                            ?: "audio/mp4"
                        try {
                            val f = File(src ?: "")
                            if (!f.exists()) {
                                result.error("not_found", "Dosya bulunamadi", null)
                                return@setMethodCallHandler
                            }
                            val safe = title
                                .replace(Regex("[^\\p{L}\\p{N}_ -]"), "")
                                .trim()
                                .ifEmpty { "CloudTune" }
                            val fileName = "$safe$extension"
                            val values = ContentValues().apply {
                                put(MediaStore.Audio.Media.DISPLAY_NAME, fileName)
                                put(MediaStore.Audio.Media.MIME_TYPE, mime)
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
                                result.error("stream_failed", "Dosya akisi acilamadi", null)
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
