import Cocoa
import FlutterMacOS
import Metal

private struct BridgeSummary: Codable {
  let bridgeVersion: String
  let platform: String
  let metalAvailable: Bool
  let mlxFocused: Bool
  let ffiEnabled: Bool
  let errorMessage: String?
}

public class LocalModelsFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    _ = LocalModelsFlutterPlugin()
  }
}

private func makeSummaryJson() -> String {
  let summary = BridgeSummary(
    bridgeVersion: "0.1.0",
    platform: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
    metalAvailable: !MTLCopyAllDevices().isEmpty,
    mlxFocused: true,
    ffiEnabled: true,
    errorMessage: nil
  )

  let encoder = JSONEncoder()
  guard
    let data = try? encoder.encode(summary),
    let json = String(data: data, encoding: .utf8)
  else {
    return #"{"bridgeVersion":"0.1.0","platform":"macOS","metalAvailable":false,"mlxFocused":true,"ffiEnabled":true,"errorMessage":"encoding failed"}"#
  }

  return json
}

@_cdecl("flm_bridge_runtime_summary_json")
public func flm_bridge_runtime_summary_json() -> UnsafeMutablePointer<CChar>? {
  strdup(makeSummaryJson())
}

@_cdecl("flm_bridge_free_string")
public func flm_bridge_free_string(_ pointer: UnsafeMutablePointer<CChar>?) {
  guard let pointer else { return }
  free(pointer)
}
