import Foundation
import HuggingFace
import Tokenizers

private let whisperLanguageAliases: [String: String] = [
    "af": "af", "afrikaans": "af",
    "ar": "ar", "arabic": "ar",
    "be": "be", "belarusian": "be",
    "bg": "bg", "bulgarian": "bg",
    "ca": "ca", "catalan": "ca",
    "cs": "cs", "czech": "cs",
    "da": "da", "danish": "da",
    "de": "de", "german": "de",
    "el": "el", "greek": "el",
    "en": "en", "english": "en",
    "es": "es", "spanish": "es",
    "et": "et", "estonian": "et",
    "fa": "fa", "persian": "fa",
    "fi": "fi", "finnish": "fi",
    "fr": "fr", "french": "fr",
    "he": "he", "hebrew": "he",
    "hi": "hi", "hindi": "hi",
    "hu": "hu", "hungarian": "hu",
    "id": "id", "indonesian": "id",
    "it": "it", "italian": "it",
    "ja": "ja", "japanese": "ja",
    "ko": "ko", "korean": "ko",
    "lt": "lt", "lithuanian": "lt",
    "lv": "lv", "latvian": "lv",
    "ms": "ms", "malay": "ms",
    "nl": "nl", "dutch": "nl",
    "no": "no", "norwegian": "no",
    "pl": "pl", "polish": "pl",
    "pt": "pt", "portuguese": "pt",
    "ro": "ro", "romanian": "ro",
    "ru": "ru", "russian": "ru",
    "sk": "sk", "slovak": "sk",
    "sl": "sl", "slovenian": "sl",
    "sv": "sv", "swedish": "sv",
    "th": "th", "thai": "th",
    "tr": "tr", "turkish": "tr",
    "uk": "uk", "ukrainian": "uk",
    "ur": "ur", "urdu": "ur",
    "vi": "vi", "vietnamese": "vi",
    "zh": "zh", "chinese": "zh", "mandarin": "zh",
]

struct WhisperGenerationConfig: Codable, Sendable {
    let isMultilingual: Bool
    let langToID: [String: Int]
    let noTimestampsTokenID: Int?
    let prevSotTokenID: Int?
    let decoderStartTokenID: Int?
    let suppressTokens: [Int]
    let beginSuppressTokens: [Int]

    enum CodingKeys: String, CodingKey {
        case isMultilingual = "is_multilingual"
        case langToID = "lang_to_id"
        case noTimestampsTokenID = "no_timestamps_token_id"
        case prevSotTokenID = "prev_sot_token_id"
        case decoderStartTokenID = "decoder_start_token_id"
        case suppressTokens = "suppress_tokens"
        case beginSuppressTokens = "begin_suppress_tokens"
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isMultilingual = try container.decodeIfPresent(Bool.self, forKey: .isMultilingual) ?? true
        self.langToID = try container.decodeIfPresent([String: Int].self, forKey: .langToID) ?? [:]
        self.noTimestampsTokenID = try container.decodeIfPresent(Int.self, forKey: .noTimestampsTokenID)
        self.prevSotTokenID = try container.decodeIfPresent(Int.self, forKey: .prevSotTokenID)
        self.decoderStartTokenID = try container.decodeIfPresent(Int.self, forKey: .decoderStartTokenID)
        self.suppressTokens = try container.decodeIfPresent([Int].self, forKey: .suppressTokens) ?? []
        self.beginSuppressTokens = try container.decodeIfPresent([Int].self, forKey: .beginSuppressTokens) ?? []
    }

    static func load(from modelDirectory: URL) throws -> WhisperGenerationConfig {
        let url = modelDirectory.appendingPathComponent("generation_config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return WhisperGenerationConfig(
                isMultilingual: true,
                langToID: [:],
                noTimestampsTokenID: nil,
                prevSotTokenID: nil,
                decoderStartTokenID: nil,
                suppressTokens: [],
                beginSuppressTokens: []
            )
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    init(
        isMultilingual: Bool,
        langToID: [String: Int],
        noTimestampsTokenID: Int?,
        prevSotTokenID: Int?,
        decoderStartTokenID: Int?,
        suppressTokens: [Int],
        beginSuppressTokens: [Int]
    ) {
        self.isMultilingual = isMultilingual
        self.langToID = langToID
        self.noTimestampsTokenID = noTimestampsTokenID
        self.prevSotTokenID = prevSotTokenID
        self.decoderStartTokenID = decoderStartTokenID
        self.suppressTokens = suppressTokens
        self.beginSuppressTokens = beginSuppressTokens
    }
}

public final class WhisperTokenizer {
    public enum Task: Sendable {
        case transcribe
        case translate
    }

    public let tokenizer: any Tokenizer
    let generationConfig: WhisperGenerationConfig
    let config: WhisperASRConfig

    private init(
        tokenizer: any Tokenizer,
        generationConfig: WhisperGenerationConfig,
        config: WhisperASRConfig
    ) {
        self.tokenizer = tokenizer
        self.generationConfig = generationConfig
        self.config = config
    }

    static func fromModelDirectory(
        _ modelDirectory: URL,
        config: WhisperASRConfig
    ) async throws -> WhisperTokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: modelDirectory)
        let generationConfig = try WhisperGenerationConfig.load(from: modelDirectory)
        return WhisperTokenizer(tokenizer: tokenizer, generationConfig: generationConfig, config: config)
    }

    var eot: Int { tokenizer.eosTokenId ?? config.eosTokenId }
    var sot: Int { tokenID(for: "<|startoftranscript|>") ?? generationConfig.decoderStartTokenID ?? config.decoderStartTokenId }
    var noTimestamps: Int? { tokenID(for: "<|notimestamps|>") ?? generationConfig.noTimestampsTokenID }
    var noSpeech: Int? { tokenID(for: "<|nospeech|>") }
    var transcribe: Int? { tokenID(for: "<|transcribe|>") }
    var translate: Int? { tokenID(for: "<|translate|>") }
    var sotPrev: Int? { tokenID(for: "<|startofprev|>") ?? generationConfig.prevSotTokenID }
    var sotLM: Int? { tokenID(for: "<|startoflm|>") }
    var timestampBegin: Int? { tokenID(for: "<|0.00|>") }

    var allLanguageTokens: [(code: String, id: Int)] {
        generationConfig.langToID
            .map { key, value in
                let code = key.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")
                return (code, value)
            }
            .sorted { $0.id < $1.id }
    }

    func tokenID(for token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }

    func normalizeLanguage(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trimmed.isEmpty else {
            return nil
        }
        return whisperLanguageAliases[trimmed] ?? trimmed
    }

    func languageToken(for rawLanguage: String?) -> Int? {
        guard let code = normalizeLanguage(rawLanguage) else { return nil }
        if let token = generationConfig.langToID["<|\(code)|>"] {
            return token
        }
        return tokenID(for: "<|\(code)|>")
    }

    func initialTokens(language: String?, task: Task = .transcribe, includeNoTimestamps: Bool = true) -> [Int] {
        var tokens = [sot]
        if generationConfig.isMultilingual, let languageToken = languageToken(for: language) {
            tokens.append(languageToken)
            if let taskToken = task == .translate ? translate : transcribe {
                tokens.append(taskToken)
            }
        }
        if includeNoTimestamps, let noTimestamps {
            tokens.append(noTimestamps)
        }
        return tokens
    }

    func detectLanguageTokenMask(vocabSize: Int) -> [Float] {
        var mask = [Float](repeating: -Float.infinity, count: vocabSize)
        for (_, id) in allLanguageTokens where id >= 0 && id < vocabSize {
            mask[id] = 0
        }
        return mask
    }

    func suppressMask(vocabSize: Int) -> [Float] {
        var mask = [Float](repeating: 0, count: vocabSize)
        let tokensToSuppress = Set(
            generationConfig.suppressTokens
                + generationConfig.beginSuppressTokens
                + [transcribe, translate, sotPrev, sotLM, sot, noSpeech].compactMap { $0 }
        )
        for token in tokensToSuppress where token >= 0 && token < vocabSize {
            mask[token] = -Float.infinity
        }
        if let timestampBegin {
            for token in timestampBegin..<vocabSize {
                mask[token] = -Float.infinity
            }
        }
        return mask
    }

    func blankSuppressMask(vocabSize: Int) -> [Float] {
        var mask = [Float](repeating: 0, count: vocabSize)
        for token in tokenizer.encode(text: " ", addSpecialTokens: false) + [eot] where token >= 0 && token < vocabSize {
            mask[token] = -Float.infinity
        }
        return mask
    }

    func decode(tokens: [Int]) -> String {
        let filtered: [Int]
        if let timestampBegin {
            filtered = tokens.filter { $0 < timestampBegin }
        } else {
            filtered = tokens
        }
        return tokenizer.decode(tokens: filtered, skipSpecialTokens: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
