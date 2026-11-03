package com.specknet.pdiot

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Phone battery for the Performance tab (lib/services/device_stats.dart):
    // level, charging, instantaneous current (µA) and voltage (mV), so the app
    // can show the phone's power draw while it is collecting data.
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
                } else {
                    result.notImplemented()
                }
            }
    }
}
