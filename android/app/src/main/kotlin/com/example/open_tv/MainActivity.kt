package dev.fredol.open_tv

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "cz.smotrim.player/launch"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchedFromBoot" -> {
                        val fromBoot = intent?.getBooleanExtra("autostart", false) ?: false
                        result.success(fromBoot)
                    }
                    "setAutostart" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        getSharedPreferences("smotrim", Context.MODE_PRIVATE)
                            .edit()
                            .putBoolean("autostart_enabled", enabled)
                            .apply()
                        result.success(null)
                    }
                    "isPackageInstalled" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val installed = try {
                            packageManager.getPackageInfo(pkg, 0)
                            true
                        } catch (e: Exception) {
                            false
                        }
                        result.success(installed)
                    }
                    "timeZoneInfo" -> {
                        // The IANA id ("Europe/Prague") the box is configured
                        // with, plus the offset in force right now. Dart only
                        // exposes the abbreviation, and the id is what makes a
                        // misconfigured box obvious in Settings.
                        val tz = java.util.TimeZone.getDefault()
                        val now = System.currentTimeMillis()
                        result.success(
                            mapOf(
                                "id" to tz.id,
                                "offsetMinutes" to tz.getOffset(now) / 60000,
                                "dst" to tz.inDaylightTime(java.util.Date(now)),
                                "country" to resources.configuration.locales[0].country
                            )
                        )
                    }
                    "setKeepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        runOnUiThread {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    "hasOverlayPermission" -> {
                        // SYSTEM_ALERT_WINDOW exempts the app from Android 12+/14
                        // background-activity-launch limits, so the boot receiver
                        // can actually start the app.
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "requestOverlayPermission" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:$packageName")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        } catch (e: Exception) {
                            try {
                                startActivity(
                                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                            } catch (_: Exception) {
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
