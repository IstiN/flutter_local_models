import Foundation
import Metal

public struct RuntimeSummary: Codable, Equatable {
    public let bridgeVersion: String
    public let platform: String
    public let metalAvailable: Bool
    public let mlxFocused: Bool
    public let ffiEnabled: Bool
    public let errorMessage: String?
}

public enum MLXBridge {
    public static func runtimeSummary() -> RuntimeSummary {
        RuntimeSummary(
            bridgeVersion: "0.1.0",
            platform: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            metalAvailable: !MTLCopyAllDevices().isEmpty,
            mlxFocused: true,
            ffiEnabled: true,
            errorMessage: nil
        )
    }

    public static func runtimeSummaryJson() throws -> String {
        let data = try JSONEncoder().encode(runtimeSummary())
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MLXBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode runtime summary."])
        }
        return json
    }
}

@_cdecl("flm_standalone_runtime_summary_json")
public func flm_standalone_runtime_summary_json() -> UnsafeMutablePointer<CChar>? {
    do {
        return strdup(try MLXBridge.runtimeSummaryJson())
    } catch {
        return strdup("{\"bridgeVersion\":\"0.1.0\",\"platform\":\"macOS\",\"metalAvailable\":false,\"mlxFocused\":true,\"ffiEnabled\":true,\"errorMessage\":\"encoding failed\"}")
    }
}

@_cdecl("flm_standalone_free_string")
public func flm_standalone_free_string(_ pointer: UnsafeMutablePointer<CChar>?) {
    guard let pointer else { return }
    free(pointer)
}
