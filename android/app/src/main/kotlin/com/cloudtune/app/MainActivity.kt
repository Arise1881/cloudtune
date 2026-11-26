package com.cloudtune.app

import android.Manifest
import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cloudtune/app_icon")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setIcon" -> {
                        val icon = call.argument<String>("icon") ?: "default"
                        try {
                            setLauncherIcon(icon)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("icon_failed", e.message, null)
                        }
                    }
                    "getIcon" -> {
                        try {
                            result.success(getCurrentLauncherIcon())
                        } catch (e: Exception) {
                            result.error("icon_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cloudtune/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bringToFront" -> {
                        try {
                            val intent = Intent(this, MainActivity::class.java)
                            intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("bring_to_front_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun iconComponents(): Map<String, String> = mapOf(
        "default" to "$packageName.MainActivity",
        "blue" to "$packageName.MainActivityIconBlue",
        "purple" to "$packageName.MainActivityIconPurple",
        "amber" to "$packageName.MainActivityIconAmber",
        "mono" to "$packageName.MainActivityIconMono",
    )

    private fun setLauncherIcon(icon: String) {
        val pm = packageManager
        val components = iconComponents()
        val target = components[icon] ?: components["default"]!!
        for ((_, name) in components) {
            val state = if (name == target)
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            pm.setComponentEnabledSetting(
                ComponentName(this, name),
                state,
                PackageManager.DONT_KILL_APP
            )
        }
    }

    private fun getCurrentLauncherIcon(): String {
        val pm = packageManager
        val components = iconComponents()
        for ((key, name) in components) {
            val state = pm.getComponentEnabledSetting(ComponentName(this, name))
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                return key
            }
        }
        // Varsayılan: MainActivity manifestte etkin, aliaslar kapalı.
        return "default"
    }
}
