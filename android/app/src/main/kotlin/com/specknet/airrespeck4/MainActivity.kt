package com.specknet.pdiot

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // For the Performance tab (lib/services/device_stats.dart):
    //  battery  level, charging, instantaneous current (µA) and voltage (mV),
    //           so the app can show the phone's power draw;
    //  memory   total PSS of the app (as dumpsys meminfo / Android Studio);
    //  device   phone maker, model and Android version for the log.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pdiot/power")
            .setMethodCallHandler { call, result ->
                if (call.method == "battery") {
                    try {
                        val manager =
                            getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                        // A sticky broadcast: registering with a null receiver
                        // just returns the latest battery status.
                        val status: Intent? = registerReceiver(
                            null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                        )
                        result.success(
                            mapOf(
                                "level" to manager.getIntProperty(
                                    BatteryManager.BATTERY_PROPERTY_CAPACITY
                                ),
                                "charging" to manager.isCharging,
                                "currentMicroA" to manager.getIntProperty(
                                    BatteryManager.BATTERY_PROPERTY_CURRENT_NOW
                                ),
                                "voltageMilliV" to
                                    (status?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1)
                            )
                        )
                    } catch (e: Exception) {
                        result.error("battery", e.message, null)
                    }
                } else if (call.method == "memory") {
                    // Total PSS of this process, the same figure as
                    // "TOTAL PSS" in `adb shell dumpsys meminfo <package>`.
                    // getMemoryInfo can take tens of ms: off the main thread.
                    Thread {
                        try {
                            val info = Debug.MemoryInfo()
                            Debug.getMemoryInfo(info)
                            val values = mapOf(
                                "kind" to "android_total_pss",
                                "bytes" to info.totalPss.toLong() * 1024L,
                                "privateDirtyBytes" to
                                    info.totalPrivateDirty.toLong() * 1024L
                            )
                            runOnUiThread { result.success(values) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("memory", e.message, null) }
                        }
                    }.start()
                } else if (call.method == "device") {
                    result.success(
                        mapOf(
                            "manufacturer" to Build.MANUFACTURER,
                            "model" to Build.MODEL,
                            "osVersion" to Build.VERSION.RELEASE,
                            "sdk" to Build.VERSION.SDK_INT
                        )
                    )
                } else {
                    result.notImplemented()
                }
            }
    }
}
