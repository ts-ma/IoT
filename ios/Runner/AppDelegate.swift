import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_local_notifications: let reminders show while the app is open.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerPowerChannel(engineBridge.pluginRegistry)
  }

  /// Memory footprint of this process in bytes (TASK_VM_INFO phys_footprint).
  private static func physFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : nil
  }

  // For the Performance tab (lib/services/device_stats.dart): phone battery
  // (iOS exposes the level and charging state only; there is no public API for
  // the battery current, so power is measured with Xcode Instruments), the
  // app's memory footprint and the phone model.
  private func registerPowerChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "PdiotPower") else { return }
    let channel = FlutterMethodChannel(
      name: "pdiot/power", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "memory":
        // phys_footprint: the figure Xcode's memory gauge and iOS's memory
        // limit use (not the resident size).
        if let bytes = Self.physFootprint() {
          result(["kind": "ios_phys_footprint", "bytes": NSNumber(value: bytes)])
        } else {
          result(FlutterError(code: "memory", message: "task_info failed", details: nil))
        }
        return
      case "device":
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
          String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        result([
          "manufacturer": "Apple",
          "model": machine,  // e.g. iPhone15,2 - look up the marketing name
          "osVersion": UIDevice.current.systemVersion,
        ])
        return
      case "battery":
        break
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      let device = UIDevice.current
      device.isBatteryMonitoringEnabled = true
      let level = device.batteryLevel  // -1 when unknown (e.g. simulator)
      let state = device.batteryState
      result([
        "level": level < 0 ? -1 : Int((level * 100).rounded()),
        "charging": state == .charging || state == .full,
      ])
    }
  }
}
