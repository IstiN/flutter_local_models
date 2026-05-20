import Foundation

public struct WhisperASRConfig: Codable, Sendable {
    public struct Quantization: Codable, Sendable {
        public let bits: Int
        public let groupSize: Int

        enum CodingKeys: String, CodingKey {
            case bits
            case groupSize = "group_size"
        }
    }

    public let modelType: String
    public let vocabSize: Int
    public let numMelBins: Int
    public let dModel: Int
    public let encoderLayers: Int
    public let encoderAttentionHeads: Int
    public let encoderFfnDim: Int
    public let decoderLayers: Int
    public let decoderAttentionHeads: Int
    public let decoderFfnDim: Int
    public let maxSourcePositions: Int
    public let maxTargetPositions: Int
    public let bosTokenId: Int
    public let eosTokenId: Int
    public let decoderStartTokenId: Int
    public let scaleEmbedding: Bool
    public let quantization: Quantization?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case vocabSize = "vocab_size"
        case numMelBins = "num_mel_bins"
        case dModel = "d_model"
        case encoderLayers = "encoder_layers"
        case encoderAttentionHeads = "encoder_attention_heads"
        case encoderFfnDim = "encoder_ffn_dim"
        case decoderLayers = "decoder_layers"
        case decoderAttentionHeads = "decoder_attention_heads"
        case decoderFfnDim = "decoder_ffn_dim"
        case maxSourcePositions = "max_source_positions"
        case maxTargetPositions = "max_target_positions"
        case bosTokenId = "bos_token_id"
        case eosTokenId = "eos_token_id"
        case decoderStartTokenId = "decoder_start_token_id"
        case scaleEmbedding = "scale_embedding"
        case quantization
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelType = try container.decodeIfPresent(String.self, forKey: .modelType) ?? "whisper"
        self.vocabSize = try container.decodeIfPresent(Int.self, forKey: .vocabSize) ?? 51_865
        self.numMelBins = try container.decodeIfPresent(Int.self, forKey: .numMelBins) ?? 80
        self.dModel = try container.decodeIfPresent(Int.self, forKey: .dModel) ?? 384
        self.encoderLayers = try container.decodeIfPresent(Int.self, forKey: .encoderLayers) ?? 4
        self.encoderAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .encoderAttentionHeads) ?? 6
        self.encoderFfnDim = try container.decodeIfPresent(Int.self, forKey: .encoderFfnDim) ?? (dModel * 4)
        self.decoderLayers = try container.decodeIfPresent(Int.self, forKey: .decoderLayers) ?? 4
        self.decoderAttentionHeads = try container.decodeIfPresent(Int.self, forKey: .decoderAttentionHeads) ?? 6
        self.decoderFfnDim = try container.decodeIfPresent(Int.self, forKey: .decoderFfnDim) ?? (dModel * 4)
        self.maxSourcePositions = try container.decodeIfPresent(Int.self, forKey: .maxSourcePositions) ?? 1_500
        self.maxTargetPositions = try container.decodeIfPresent(Int.self, forKey: .maxTargetPositions) ?? 448
        self.bosTokenId = try container.decodeIfPresent(Int.self, forKey: .bosTokenId) ?? 50_257
        self.eosTokenId = try container.decodeIfPresent(Int.self, forKey: .eosTokenId) ?? 50_257
        self.decoderStartTokenId = try container.decodeIfPresent(Int.self, forKey: .decoderStartTokenId) ?? 50_258
        self.scaleEmbedding = try container.decodeIfPresent(Bool.self, forKey: .scaleEmbedding) ?? false
        self.quantization = try container.decodeIfPresent(Quantization.self, forKey: .quantization)
    }

    public static func load(from modelDirectory: URL) throws -> WhisperASRConfig {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
