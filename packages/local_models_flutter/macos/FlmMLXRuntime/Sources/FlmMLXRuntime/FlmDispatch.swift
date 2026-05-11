import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import HuggingFace
import Tokenizers

private actor ModelContainerCache {
    private var containers: [String: ModelContainer] = [:]

    func container(forModelPath path: String) async throws -> ModelContainer {
        if let cached = containers[path] {
            return cached
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw FlmDispatchError.modelPathMissing(path)
        }
        let directory = URL(fileURLWithPath: path)
        let loaded = try await loadModelContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        containers[path] = loaded
        return loaded
    }
}

private enum FlmDispatchError: LocalizedError {
    case modelPathMissing(String)

    var errorDescription: String? {
        switch self {
        case .modelPathMissing(let path):
            return "Model directory does not exist: \(path)"
        }
    }
}

private let containerCache = ModelContainerCache()

private final class GenerationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any] = [:]

    func set(_ newValue: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func jsonString(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let text = String(data: data, encoding: .utf8)
    else {
        return "{\"ok\":false,\"error\":\"failed to encode JSON response\"}"
    }
    return text
}

private func runLmGenerate(payloadData: Data) -> [String: Any] {
    let box = GenerationResultBox()
    box.set(["ok": false, "error": "MLX generation did not complete"])
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { @Sendable in
        defer { semaphore.signal() }
        guard
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            box.set(["ok": false, "error": "invalid lm.generate payload"])
            return
        }
        let out = await handleLmGenerate(payload: payload)
        box.set(out)
    }
    semaphore.wait()
    return box.get()
}

private func runAudioTranscribe(payloadData: Data) -> [String: Any] {
    let box = GenerationResultBox()
    box.set(["ok": false, "error": "ASR did not complete"])
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { @Sendable in
        defer { semaphore.signal() }
        guard
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            box.set(["ok": false, "error": "invalid audio.transcribe payload"])
            return
        }
        let out = await FlmAudioMLX.transcribe(payload: payload)
        box.set(out)
    }
    semaphore.wait()
    return box.get()
}

private func runAudioSynthesize(payloadData: Data) -> [String: Any] {
    let box = GenerationResultBox()
    box.set(["ok": false, "error": "TTS did not complete"])
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { @Sendable in
        defer { semaphore.signal() }
        guard
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            box.set(["ok": false, "error": "invalid audio.synthesize payload"])
            return
        }
        let out = await FlmAudioMLX.synthesize(payload: payload)
        box.set(out)
    }
    semaphore.wait()
    return box.get()
}

private func intFromJson(_ value: Any?) -> Int? {
    if let v = value as? Int { return v }
    if let v = value as? Int64 { return Int(v) }
    if let n = value as? NSNumber { return n.intValue }
    if let d = value as? Double { return Int(d) }
    return nil
}

private func floatFromJson(_ value: Any?) -> Float? {
    if let v = value as? Float { return v }
    if let v = value as? Double { return Float(v) }
    if let n = value as? NSNumber { return n.floatValue }
    return nil
}

private func handleLmGenerate(payload: [String: Any]) async -> [String: Any] {
    guard let modelPath = payload["modelPath"] as? String, !modelPath.isEmpty else {
        return ["ok": false, "error": "missing modelPath"]
    }
    guard let prompt = payload["prompt"] as? String else {
        return ["ok": false, "error": "missing prompt"]
    }

    let maxTokens = intFromJson(payload["maxTokens"])
    let temperature = floatFromJson(payload["temperature"])
    let topP = floatFromJson(payload["topP"])

    var generateParameters = GenerateParameters()
    generateParameters.maxTokens = maxTokens
    if let temperature {
        generateParameters.temperature = temperature
    }
    if let topP {
        generateParameters.topP = topP
    }

    let imagePath = payload["imagePath"] as? String
    let audioPath = payload["audioPath"] as? String

    if let audioPath, !audioPath.isEmpty {
        return [
            "ok": false,
            "error":
                "Audio-conditioned paths are not supported in the native MLX bridge yet (\(audioPath)).",
        ]
    }

    do {
        let modelContainer = try await containerCache.container(forModelPath: modelPath)
        let session = ChatSession(modelContainer, generateParameters: generateParameters)

        if let imagePath, !imagePath.isEmpty {
            guard FileManager.default.fileExists(atPath: imagePath) else {
                return ["ok": false, "error": "image file missing: \(imagePath)"]
            }
            let url = URL(fileURLWithPath: imagePath)
            let image = UserInput.Image.url(url)
            let text = try await session.respond(to: prompt, image: image)
            return ["ok": true, "text": text]
        }

        let text = try await session.respond(to: prompt)
        return ["ok": true, "text": text]
    } catch {
        return ["ok": false, "error": String(describing: error)]
    }
}

@_cdecl("flm_dispatch_json")
public func flm_dispatch_json(
    _ operation: UnsafePointer<CChar>?,
    _ payloadJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let operation else {
        return strdup(jsonString(["ok": false, "error": "missing operation"]))
    }
    let op = String(cString: operation)

    guard let payloadJson else {
        return strdup(jsonString(["ok": false, "error": "missing payload"]))
    }
    let payloadString = String(cString: payloadJson)
    guard let data = payloadString.data(using: .utf8) else {
        return strdup(jsonString(["ok": false, "error": "payload is not valid UTF-8"]))
    }

    let payloadObject: [String: Any]
    do {
        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = decoded as? [String: Any] else {
            return strdup(
                jsonString(["ok": false, "error": "payload must be a JSON object"]))
        }
        payloadObject = dict
    } catch {
        return strdup(
            jsonString([
                "ok": false,
                "error": "invalid JSON payload: \(error.localizedDescription)",
            ]))
    }

    let result: [String: Any]
    switch op {
    case "lm.generate":
        guard JSONSerialization.isValidJSONObject(payloadObject),
              let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject)
        else {
            return strdup(jsonString(["ok": false, "error": "lm.generate payload is not JSON-serializable"]))
        }
        result = runLmGenerate(payloadData: payloadData)
    case "audio.transcribe":
        guard JSONSerialization.isValidJSONObject(payloadObject),
              let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject)
        else {
            return strdup(
                jsonString(["ok": false, "error": "audio.transcribe payload is not JSON-serializable"])
            )
        }
        result = runAudioTranscribe(payloadData: payloadData)
    case "audio.synthesize":
        guard JSONSerialization.isValidJSONObject(payloadObject),
              let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject)
        else {
            return strdup(
                jsonString(["ok": false, "error": "audio.synthesize payload is not JSON-serializable"])
            )
        }
        result = runAudioSynthesize(payloadData: payloadData)
    case "image.generate":
        result = [
            "ok": false,
            "error": "Native MLX image generation is not implemented yet (mflux / diffusion).",
        ]
    default:
        result = ["ok": false, "error": "unknown operation: \(op)"]
    }

    return strdup(jsonString(result))
}
