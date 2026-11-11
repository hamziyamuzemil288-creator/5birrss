package com.amistbirr.myapp

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The Notification Settings screen needs a door to Android's own
        // notification screen after a denial: the OS will not show the
        // permission prompt twice. Using a small method channel avoids adding a
        // settings plugin just for one Intent.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "aliob/notifications"
        ).setMethodCallHandler { call, result ->
            if (call.method != "openNotificationSettings") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    }
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                }
                startActivity(intent)
                result.success(null)
            } catch (e: Exception) {
                result.error("SETTINGS_UNAVAILABLE", e.message, null)
            }
        }
    }
}
