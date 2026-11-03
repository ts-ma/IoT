import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerPowerChannel(engineBridge.pluginRegistry)
  }

  // Phone battery for the Performance tab (lib/services/device_stats.dart).
  // iOS exposes the level and charging state only; there is no public API for
  // the battery current, so power is measured with Xcode Instruments.
  private func registerPowerChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "PdiotPower") else { return }
    let channel = FlutterMethodChannel(
      name: "pdiot/power", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "battery" else {
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
