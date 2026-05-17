import CoreFoundation
import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import HuggingFace
import Tokenizers

private actor ModelContainerCache {
    private var containers: [String: ModelContainer] = [:]

    /// Returns the model container together with a flag indicating whether the
    /// container was already in the cache (`true`) or had to be loaded (`false`).
    func container(forModelPath path: String) async throws -> (container: ModelContainer, cacheHit: Bool) {
        if let cached = containers[path] {
            return (cached, true)
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
        return (loaded, false)
    }
}

private enum FlmDispatchError: LocalizedError {
    case modelPathMissing(String)
    case invalidToolsPayload(String)
    case toolEncodeFailed
    case toolBridgeNotStarted
    case toolBridgeTimeout
    case toolBridgeEmpty

    var errorDescription: String? {
        switch self {
        case .modelPathMissing(let path):
            return "Model directory does not exist: \(path)"
        case .invalidToolsPayload(let message):
            return message
        case .toolEncodeFailed:
            return "Failed to JSON-encode a ToolCall for the Dart bridge."
        case .toolBridgeNotStarted:
            return "Internal tool bridge was not initialized."
        case .toolBridgeTimeout:
            return "Timed out waiting for Dart tool handler."
        case .toolBridgeEmpty:
            return "Tool bridge finished without a result."
        }
    }
}

private let containerCache = ModelContainerCache()

// MARK: - Dart tool bridge (one in-flight tool call per process)

private final class FlmToolBridgeState: @unchecked Sendable {
    private let lock = NSLock()
    private var semaphore: DispatchSemaphore?
    private var result: String?
    private var error: String?

    func beginExchange() {
        lock.lock()
        semaphore = DispatchSemaphore(value: 0)
        result = nil
        error = nil
        lock.unlock()
    }

    func completeSuccess(_ text: String) {
        lock.lock()
        result = text
        error = nil
        semaphore?.signal()
        lock.unlock()
    }

    func completeFailure(_ message: String) {
        lock.lock()
        error = message
        result = nil
        semaphore?.signal()
        lock.unlock()
    }

    func waitForResult() throws -> String {
        lock.lock()
        let sem = semaphore
        lock.unlock()
        guard let sem else {
            throw FlmDispatchError.toolBridgeNotStarted
        }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            throw FlmDispatchError.toolBridgeTimeout
        }
        lock.lock()
        semaphore = nil
        let err = error
        let ok = result
        error = nil
        result = nil
        lock.unlock()
        if let err, !err.isEmpty {
            throw NSError(
                domain: "FlmToolBridge", code: 2,
                userInfo: [NSLocalizedDescriptionKey: err])
        }
        guard let ok else {
            throw FlmDispatchError.toolBridgeEmpty
        }
        return ok
    }
}

private let flmToolBridge = FlmToolBridgeState()

@_cdecl("flm_tool_bridge_complete")
public func flm_tool_bridge_complete(_ result: UnsafePointer<CChar>?) {
    let text = result.map { String(cString: $0) } ?? ""
    flmToolBridge.completeSuccess(text)
}

@_cdecl("flm_tool_bridge_abort")
public func flm_tool_bridge_abort(_ err: UnsafePointer<CChar>?) {
    let text = err.map { String(cString: $0) } ?? "tool error"
    flmToolBridge.completeFailure(text)
}

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

public typealias FlmStreamChunkCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

public typealias FlmToolRequestCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

private func prepareToolBridgeForNextCall() {
    flmToolBridge.beginExchange()
}

private func takeToolBridgeResult() throws -> String {
    try flmToolBridge.waitForResult()
}

private func sendableJSONObject(_ json: Any) throws -> any Sendable {
    switch json {
    case let s as String:
        return s
    case let b as Bool:
        return b
    case let i as Int:
        return i
    case let i64 as Int64:
        return Int(i64)
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue
        }
        if CFNumberIsFloatType(n) {
            return n.doubleValue
        }
        return n.intValue
    case let arr as [Any]:
        return try arr.map { try sendableJSONObject($0) }
    case let dict as [String: Any]:
        return try sendableDict(dict)
    case is NSNull:
        return ""
    default:
        throw FlmDispatchError.invalidToolsPayload(
            "Unsupported JSON value in tools payload: \(String(describing: json))")
    }
}

private func sendableDict(_ dict: [String: Any]) throws -> [String: any Sendable] {
    var out: [String: any Sendable] = [:]
    out.reserveCapacity(dict.count)
    for (key, value) in dict {
        out[key] = try sendableJSONObject(value)
    }
    return out
}

private func parseToolsPayload(_ value: Any?) throws -> [ToolSpec]? {
    guard let value else {
        return nil
    }
    guard let array = value as? [Any] else {
        throw FlmDispatchError.invalidToolsPayload("`tools` must be a JSON array")
    }
    if array.isEmpty {
        return []
    }
    var specs: [ToolSpec] = []
    specs.reserveCapacity(array.count)
    for item in array {
        guard let dict = item as? [String: Any] else {
            throw FlmDispatchError.invalidToolsPayload("Each tool must be a JSON object")
        }
        specs.append(try sendableDict(dict))
    }
    return specs
}

private func toolListenerFromPayload(_ payload: [String: Any]) -> FlmToolRequestCallback? {
    guard let addr = intFromJson(payload["toolListener"]), addr != 0 else {
        return nil
    }
    return unsafeBitCast(UInt(addr), to: FlmToolRequestCallback.self)
}

private func makeToolDispatch(
    listener: FlmToolRequestCallback?,
) -> (@Sendable (ToolCall) async throws -> String)? {
    guard let listener else {
        return nil
    }
    return { call in
        let data = try JSONEncoder().encode(call)
        guard let json = String(data: data, encoding: .utf8) else {
            throw FlmDispatchError.toolEncodeFailed
        }
        prepareToolBridgeForNextCall()
        guard let dup = strdup(json) else {
            throw FlmDispatchError.toolEncodeFailed
        }
        listener(UnsafePointer(dup), nil)
        return try takeToolBridgeResult()
    }
}

private func makeChatSession(
    modelContainer: ModelContainer,
    generateParameters: GenerateParameters,
    enableThinking: Bool?,
    tools: [ToolSpec]?,
    toolDispatch: (@Sendable (ToolCall) async throws -> String)?
) -> ChatSession {
    let additionalContext: [String: any Sendable]? = enableThinking.map { ["enable_thinking": $0] }
    if let tools, !tools.isEmpty {
        return ChatSession(
            modelContainer,
            generateParameters: generateParameters,
            additionalContext: additionalContext,
            tools: tools,
            toolDispatch: toolDispatch
        )
    }
    return ChatSession(modelContainer, generateParameters: generateParameters,
                       additionalContext: additionalContext)
}

/// Parse a Dart `messages` array (each entry `{role, content}`) into a
/// `ChatSession`-initialisation triple:
///   - `instructions`  – the system message content (nil if none)
///   - `history`       – all messages except the last user message
///   - `lastUserMessage` – the final user turn to pass to `respond(to:)`
///
/// Falls back to `(nil, [], prompt)` when the payload contains only the
/// legacy `prompt` string (no `messages` array).
private func parseMessagesPayload(
    _ payload: [String: Any]
) -> (instructions: String?, history: [Chat.Message], lastUserMessage: String) {
    guard let rawMessages = payload["messages"] as? [[String: String]],
          !rawMessages.isEmpty
    else {
        // Legacy path: flat prompt string
        let prompt = payload["prompt"] as? String ?? ""
        return (nil, [], prompt)
    }

    var instructions: String? = nil
    var history: [Chat.Message] = []

    for entry in rawMessages {
        let role = entry["role"] ?? "user"
        let content = entry["content"] ?? ""
        switch role {
        case "system":
            instructions = content
        case "user":
            history.append(Chat.Message(role: .user, content: content))
        case "assistant":
            history.append(Chat.Message(role: .assistant, content: content))
        case "tool":
            history.append(Chat.Message(role: .tool, content: content))
        default:
            history.append(Chat.Message(role: .user, content: content))
        }
    }

    // The last user message is passed to respond(to:); everything before it
    // is the history the ChatSession is pre-loaded with.
    var lastUserMessage = ""
    var historyWithoutLast = history

    // Walk backwards to find the last user-role entry.
    for i in stride(from: history.count - 1, through: 0, by: -1) {
        if history[i].role == .user {
            lastUserMessage = history[i].content
            historyWithoutLast.remove(at: i)
            break
        }
    }

    return (instructions, historyWithoutLast, lastUserMessage)
}

private func makeChatSessionWithHistory(
    modelContainer: ModelContainer,
    generateParameters: GenerateParameters,
    enableThinking: Bool?,
    instructions: String?,
    history: [Chat.Message],
    tools: [ToolSpec]?,
    toolDispatch: (@Sendable (ToolCall) async throws -> String)?
) -> ChatSession {
    let additionalContext: [String: any Sendable]? = enableThinking.map { ["enable_thinking": $0] }
    if let tools, !tools.isEmpty {
        if !history.isEmpty {
            return ChatSession(
                modelContainer,
                instructions: instructions,
                history: history,
                generateParameters: generateParameters,
                additionalContext: additionalContext,
                tools: tools,
                toolDispatch: toolDispatch
            )
        }
        return ChatSession(
            modelContainer,
            instructions: instructions,
            generateParameters: generateParameters,
            additionalContext: additionalContext,
            tools: tools,
            toolDispatch: toolDispatch
        )
    }
    if !history.isEmpty {
        return ChatSession(
            modelContainer,
            instructions: instructions,
            history: history,
            generateParameters: generateParameters,
            additionalContext: additionalContext
        )
    }
    return ChatSession(
        modelContainer,
        instructions: instructions,
        generateParameters: generateParameters,
        additionalContext: additionalContext
    )
}

/// Logs the full LLM request to stdout so it appears in the Flutter run console.
private func logLmRequest(
    instructions: String?,
    history: [Chat.Message],
    prompt: String,
    maxTokens: Int?,
    temperature: Float?,
    enableThinking: Bool?
) {
    print("flutter: [LLM→Swift] ══════════════════════════════════════════════")
    print("flutter: [LLM→Swift] enableThinking: \(enableThinking.map { "\($0)" } ?? "nil (not set)")")
    print("flutter: [LLM→Swift] maxTokens: \(maxTokens.map { "\($0)" } ?? "nil")")
    print("flutter: [LLM→Swift] temperature: \(temperature.map { "\($0)" } ?? "nil")")
    if let sys = instructions {
        let preview = sys.count > 200 ? String(sys.prefix(200)) + "…" : sys
        print("flutter: [LLM→Swift] instructions (\(sys.count) chars): \(preview)")
    } else {
        print("flutter: [LLM→Swift] instructions: nil")
    }
    print("flutter: [LLM→Swift] history (\(history.count) messages):")
    for (i, msg) in history.enumerated() {
        let preview = msg.content.count > 150 ? String(msg.content.prefix(150)) + "…" : msg.content
        print("flutter: [LLM→Swift]   [\(i)] \(msg.role): \(preview)")
    }
    print("flutter: [LLM→Swift] prompt (last user msg): \(prompt)")
    print("flutter: [LLM→Swift] ══════════════════════════════════════════════")
}

/// Appends `/no_think` or `/think` to the user message for Qwen3-style thinking models.
/// When `enableThinking` is `false`, appends `/no_think` to suppress the thinking block.
/// When `enableThinking` is `true`, appends `/think` to explicitly request thinking.
/// When `nil` (not set), the message is returned unchanged (model default).
private func applyThinkingSwitch(_ message: String, enableThinking: Bool?) -> String {
    guard let enable = enableThinking else { return message }
    let stripped = message
        .replacingOccurrences(of: " /no_think", with: "")
        .replacingOccurrences(of: " /think", with: "")
        .replacingOccurrences(of: "/no_think", with: "")
        .replacingOccurrences(of: "/think", with: "")
        .trimmingCharacters(in: .whitespaces)
    return stripped + (enable ? " /think" : " /no_think")
}

private func handleLmGenerate(payload: [String: Any]) async -> [String: Any] {
    guard let modelPath = payload["modelPath"] as? String, !modelPath.isEmpty else {
        return ["ok": false, "error": "missing modelPath"]
    }

    let (instructions, history, rawPrompt) = parseMessagesPayload(payload)
    if rawPrompt.isEmpty {
        return ["ok": false, "error": "missing prompt or messages"]
    }

    // Qwen3 thinking soft-switch: append /no_think to disable thinking mode.
    let enableThinking = payload["enableThinking"] as? Bool
    let prompt = applyThinkingSwitch(rawPrompt, enableThinking: enableThinking)

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
                "Audio-conditioned generation is not supported in the native MLX bridge. "
                + "Transcribe the audio first (e.g. with a Whisper ASR model) and pass the "
                + "transcript as a text prompt. Audio path received: \(audioPath)",
        ]
    }

    let tools: [ToolSpec]?
    do {
        tools = try parseToolsPayload(payload["tools"])
    } catch {
        return ["ok": false, "error": error.localizedDescription]
    }
    let listener = toolListenerFromPayload(payload)
    if let tools, !tools.isEmpty, listener == nil {
        return [
            "ok": false,
            "error":
                "Native tool calling requires `toolListener` (Dart NativeCallable address) when `tools` is non-empty.",
        ]
    }
    let toolDispatch = makeToolDispatch(listener: listener)

    let t0 = Date()
    do {
        let (modelContainer, cacheHit) = try await containerCache.container(forModelPath: modelPath)
        let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        let session = makeChatSessionWithHistory(
            modelContainer: modelContainer,
            generateParameters: generateParameters,
            enableThinking: enableThinking,
            instructions: instructions,
            history: history,
            tools: tools,
            toolDispatch: toolDispatch
        )

        let tGen = Date()
        if let imagePath, !imagePath.isEmpty {
            guard FileManager.default.fileExists(atPath: imagePath) else {
                return ["ok": false, "error": "image file missing: \(imagePath)"]
            }
            let url = URL(fileURLWithPath: imagePath)
            let image = UserInput.Image.url(url)
            let text = try await session.respond(to: prompt, image: image)
            let generateMs = Int(Date().timeIntervalSince(tGen) * 1000)
            return ["ok": true, "text": text,
                    "swiftCacheHit": cacheHit, "swiftLoadMs": loadMs,
                    "swiftGenerateMs": generateMs, "swiftFirstTokenMs": generateMs,
                    "swiftTotalMs": Int(Date().timeIntervalSince(t0) * 1000)]
        }

        let text = try await session.respond(to: prompt)
        let generateMs = Int(Date().timeIntervalSince(tGen) * 1000)
        return ["ok": true, "text": text,
                "swiftCacheHit": cacheHit, "swiftLoadMs": loadMs,
                "swiftGenerateMs": generateMs, "swiftFirstTokenMs": generateMs,
                "swiftTotalMs": Int(Date().timeIntervalSince(t0) * 1000)]
    } catch {
        return ["ok": false, "error": String(describing: error),
                "swiftTotalMs": Int(Date().timeIntervalSince(t0) * 1000)]
    }
}

private func emitStreamChunk(
    _ chunk: String,
    _ callback: FlmStreamChunkCallback?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let callback else {
        return
    }
    guard !chunk.isEmpty else {
        return
    }
    chunk.withCString { base in
        guard let dup = strdup(base) else {
            return
        }
        callback(UnsafePointer(dup), userData)
        // Ownership: Dart listener copies/frees `dup`.
    }
}

private func handleLmGenerateStreaming(
    payload: [String: Any],
    chunkCallback: FlmStreamChunkCallback?,
    userData: UnsafeMutableRawPointer?
) async -> [String: Any] {
    guard let modelPath = payload["modelPath"] as? String, !modelPath.isEmpty else {
        return ["ok": false, "error": "missing modelPath"]
    }

    let (instructions, history, rawPrompt) = parseMessagesPayload(payload)
    if rawPrompt.isEmpty {
        return ["ok": false, "error": "missing prompt or messages"]
    }

    // Qwen3 thinking soft-switch: append /no_think to disable thinking mode.
    let enableThinking = payload["enableThinking"] as? Bool
    let prompt = applyThinkingSwitch(rawPrompt, enableThinking: enableThinking)

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

    // ── Swift-level LLM request debug log ────────────────────────────────────
    logLmRequest(instructions: instructions, history: history, prompt: prompt,
                 maxTokens: maxTokens, temperature: temperature,
                 enableThinking: enableThinking)

    let imagePath = payload["imagePath"] as? String
    let audioPath = payload["audioPath"] as? String

    if let audioPath, !audioPath.isEmpty {
        return [
            "ok": false,
            "error":
                "Audio-conditioned generation is not supported in the native MLX bridge. "
                + "Transcribe the audio first (e.g. with a Whisper ASR model) and pass the "
                + "transcript as a text prompt. Audio path received: \(audioPath)",
        ]
    }

    let tools: [ToolSpec]?
    do {
        tools = try parseToolsPayload(payload["tools"])
    } catch {
        return ["ok": false, "error": error.localizedDescription]
    }
    let listener = toolListenerFromPayload(payload)
    if let tools, !tools.isEmpty, listener == nil {
        return [
            "ok": false,
            "error":
                "Native tool calling requires `toolListener` (Dart NativeCallable address) when `tools` is non-empty.",
        ]
    }
    let toolDispatch = makeToolDispatch(listener: listener)

    guard let chunkCallback else {
        return await handleLmGenerate(payload: payload)
    }

    let t0 = Date()
    do {
        let (modelContainer, cacheHit) = try await containerCache.container(forModelPath: modelPath)
        let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        let session = makeChatSessionWithHistory(
            modelContainer: modelContainer,
            generateParameters: generateParameters,
            enableThinking: enableThinking,
            instructions: instructions,
            history: history,
            tools: tools,
            toolDispatch: toolDispatch
        )
        var accumulated = ""
        var firstTokenMs: Int = -1
        let tGen = Date()

        if let imagePath, !imagePath.isEmpty {
            guard FileManager.default.fileExists(atPath: imagePath) else {
                return ["ok": false, "error": "image file missing: \(imagePath)"]
            }
            let url = URL(fileURLWithPath: imagePath)
            let image = UserInput.Image.url(url)
            for try await piece in session.streamResponse(to: prompt, image: image) {
                if firstTokenMs < 0 && !piece.isEmpty {
                    firstTokenMs = Int(Date().timeIntervalSince(tGen) * 1000)
                }
                accumulated += piece
                emitStreamChunk(piece, chunkCallback, userData)
            }
        } else {
            for try await piece in session.streamResponse(to: prompt) {
                if firstTokenMs < 0 && !piece.isEmpty {
                    firstTokenMs = Int(Date().timeIntervalSince(tGen) * 1000)
                }
                accumulated += piece
                emitStreamChunk(piece, chunkCallback, userData)
            }
        }
        let generateMs = Int(Date().timeIntervalSince(tGen) * 1000)
        if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ["ok": false, "error": "Native LM returned empty text",
                    "swiftCacheHit": cacheHit, "swiftLoadMs": loadMs,
                    "swiftTotalMs": Int(Date().timeIntervalSince(t0) * 1000)]
        }
        return ["ok": true, "text": accumulated,
                "swiftCacheHit": cacheHit, "swiftLoadMs": loadMs,
                "swiftFirstTokenMs": firstTokenMs,
                "swiftGenerateMs": generateMs,
                "swiftTotalMs": Int(Date().timeIntervalSince(t0) * 1000)]
    } catch {
        return ["ok": false, "error": String(describing: error),
                "swiftTotalMs": Int(Date().timeIntervalSince(t0) * 1000)]
    }
}

private func runLmGenerateStreaming(
    payloadData: Data,
    chunkCallback: FlmStreamChunkCallback?,
    userData: UnsafeMutableRawPointer?
) -> [String: Any] {
    let box = GenerationResultBox()
    box.set(["ok": false, "error": "MLX streaming generation did not complete"])
    let semaphore = DispatchSemaphore(value: 0)
    let userDataBits = UInt(bitPattern: userData)
    Task.detached { @Sendable in
        defer { semaphore.signal() }
        guard
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            box.set(["ok": false, "error": "invalid lm.generate payload"])
            return
        }
        let ud = userDataBits == 0 ? nil : UnsafeMutableRawPointer(bitPattern: userDataBits)
        let out = await handleLmGenerateStreaming(
            payload: payload,
            chunkCallback: chunkCallback,
            userData: ud
        )
        box.set(out)
    }
    semaphore.wait()
    return box.get()
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

@_cdecl("flm_dispatch_json_stream")
public func flm_dispatch_json_stream(
    _ operation: UnsafePointer<CChar>?,
    _ payloadJson: UnsafePointer<CChar>?,
    _ chunkCallback: FlmStreamChunkCallback?,
    _ userData: UnsafeMutableRawPointer?
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
        result = runLmGenerateStreaming(
            payloadData: payloadData,
            chunkCallback: chunkCallback,
            userData: userData
        )
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
