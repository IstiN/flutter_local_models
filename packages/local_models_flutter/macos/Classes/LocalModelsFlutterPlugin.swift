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

private func flmJsonResponse(_ object: [String: Any]) -> UnsafeMutablePointer<CChar>? {
  guard JSONSerialization.isValidJSONObject(object),
        let data = try? JSONSerialization.data(withJSONObject: object, options: []),
        let json = String(data: data, encoding: .utf8)
  else {
    return strdup(#"{"ok":false,"error":"failed to encode response"}"#)
  }
  return strdup(json)
}

/// JSON-RPC style entry for Dart `FlmNativeDispatcher`: `(operation, payloadJson) -> resultJson`.
@_cdecl("flm_dispatch_json")
public func flm_dispatch_json(
  _ operation: UnsafePointer<CChar>?,
  _ payloadJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
  guard let operation else {
    return flmJsonResponse(["ok": false, "error": "missing operation"])
  }
  let op = String(cString: operation)
  guard let payloadJson else {
    return flmJsonResponse(["ok": false, "error": "missing payload"])
  }
  let payloadString = String(cString: payloadJson)
  guard let data = payloadString.data(using: .utf8) else {
    return flmJsonResponse(["ok": false, "error": "payload is not valid UTF-8"])
  }
  let payloadObject: [String: Any]
  do {
    let decoded = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = decoded as? [String: Any] else {
      return flmJsonResponse(["ok": false, "error": "payload must be a JSON object"])
    }
    payloadObject = dict
  } catch {
    return flmJsonResponse(["ok": false, "error": "invalid JSON payload: \(error.localizedDescription)"])
  }

  let modelPath = payloadObject["modelPath"] as? String ?? ""
  switch op {
  case "lm.generate":
    return flmJsonResponse([
      "ok": false,
      "error": "MLX text generation is not wired yet. Integrate mlx-swift-lm and load \(modelPath)"
    ])
  case "audio.transcribe":
    return flmJsonResponse([
      "ok": false,
      "error": "Native speech-to-text is not wired yet."
    ])
  case "audio.synthesize":
    return flmJsonResponse([
      "ok": false,
      "error": "Native text-to-speech is not wired yet."
    ])
  case "image.generate":
    return flmJsonResponse([
      "ok": false,
      "error": "Native image generation is not wired yet."
    ])
  default:
    return flmJsonResponse(["ok": false, "error": "unknown operation: \(op)"])
  }
}
