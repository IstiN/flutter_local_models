#!/usr/bin/env python3
"""Patch mlx-swift-lm MLXVLM ``Gemma4.swift`` for native Gemma4 ASR (prepareAudioTranscription).

Run from repo root after SPM has resolved mlx-swift-lm (``swift build`` / Xcode / Flutter):

    python3 packages/local_models_flutter/macos/FlmMLXRuntime/scripts/patch_mlx_checkout_gemma4_audio.py

Patches every checkout found under this repo:
  - ``FlmMLXRuntime/.build/checkouts/mlx-swift-lm/...``
  - ``**/SourcePackages/checkouts/mlx-swift-lm/...`` (Flutter macOS build, etc.)

Checkouts are often read-only until ``chmod``. Idempotent per file.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _repo_root() -> Path:
    # scripts/patch_*.py → …/FlmMLXRuntime/scripts → up to repo root
    return Path(__file__).resolve().parents[5]


def _collect_gemma4_paths(repo: Path) -> list[Path]:
    exact = (
        repo
        / "packages"
        / "local_models_flutter"
        / "macos"
        / "FlmMLXRuntime"
        / ".build"
        / "checkouts"
        / "mlx-swift-lm"
        / "Libraries"
        / "MLXVLM"
        / "Models"
        / "Gemma4.swift"
    )
    found: dict[str, Path] = {}
    if exact.is_file():
        found[str(exact.resolve())] = exact
    for p in repo.glob(
        "**/SourcePackages/checkouts/mlx-swift-lm/Libraries/MLXVLM/Models/Gemma4.swift"
    ):
        if p.is_file():
            found[str(p.resolve())] = p
    return sorted(found.values(), key=lambda x: str(x))


def _patch_one(gemma4: Path) -> str:
    os.chmod(gemma4, 0o644)
    text = gemma4.read_text()
    if "prepareAudioTranscription" in text:
        return f"already patched: {gemma4}"

    old_err = """private enum Gemma4Error: LocalizedError {
    case imageTokenCountMismatch(expectedVisionTokens: Int, actualPromptTokens: Int)

    var errorDescription: String? {
        switch self {
        case .imageTokenCountMismatch(let expectedVisionTokens, let actualPromptTokens):
            return
                "Gemma4 image token count mismatch: vision encoder produced \\(expectedVisionTokens) soft tokens, but the prompt contains \\(actualPromptTokens) image tokens."
        }
    }
}"""
    new_err = """private enum Gemma4Error: LocalizedError {
    case imageTokenCountMismatch(expectedVisionTokens: Int, actualPromptTokens: Int)
    case audioTokenCountMismatch(expectedEncoderTokens: Int, actualPromptTokens: Int)
    case audioNotSupported

    var errorDescription: String? {
        switch self {
        case .imageTokenCountMismatch(let expectedVisionTokens, let actualPromptTokens):
            return
                "Gemma4 image token count mismatch: vision encoder produced \\(expectedVisionTokens) soft tokens, but the prompt contains \\(actualPromptTokens) image tokens."
        case .audioTokenCountMismatch(let expectedEncoderTokens, let actualPromptTokens):
            return
                "Gemma4 audio token count mismatch: audio encoder produced \\(expectedEncoderTokens) soft tokens, but the prompt contains \\(actualPromptTokens) audio tokens."
        case .audioNotSupported:
            return "Gemma4 configuration is missing audio_token_id; this checkpoint does not support audio input."
        }
    }
}"""
    if old_err not in text:
        return f"skip (unexpected Gemma4Error / upstream changed): {gemma4}"

    text = text.replace(old_err, new_err, 1)

    anchor = """        return (inputsEmbeds, perLayerInputs)
    }

    public func prepare(_ input: LMInput, cache: [any KVCache], windowSize: Int?) throws
        -> PrepareResult
    {"""
    insert = """        return (inputsEmbeds, perLayerInputs)
    }

    /// Native ASR / audio-soft-token prefill: merges ``audioFeatures`` (from the audio tower)
    /// into the scaled text embedding sequence at every `<|audio|>` token position.
    public func prepareAudioTranscription(
        inputIds: MLXArray,
        audioFeatures: MLXArray,
        cache: [any KVCache]
    ) throws -> PrepareResult {
        guard let audioTokenId = config.audioTokenId else {
            throw Gemma4Error.audioNotSupported
        }

        let (baseEmbeds, perLayerInputs) = try getInputEmbeddings(
            inputIds: inputIds, pixelValues: nil)

        let audioMask = inputIds .== audioTokenId
        let expectedAudioTokens = audioMask.asType(.int32).sum().item(Int.self)
        if expectedAudioTokens != audioFeatures.dim(1) {
            throw Gemma4Error.audioTokenCountMismatch(
                expectedEncoderTokens: audioFeatures.dim(1),
                actualPromptTokens: expectedAudioTokens)
        }

        var maskExpanded = expandedDimensions(audioMask, axis: -1)
        maskExpanded = broadcast(maskExpanded, to: baseEmbeds.shape)
        let inputsEmbeds = gemma4MaskedScatter(
            inputTensor: baseEmbeds,
            mask: maskExpanded,
            source: audioFeatures.asType(baseEmbeds.dtype)
        )

        let result = languageModel(
            nil,
            cache: cache.map { $0 },
            inputsEmbeds: inputsEmbeds,
            perLayerInputs: perLayerInputs
        )
        return .logits(result)
    }

    public func prepare(_ input: LMInput, cache: [any KVCache], windowSize: Int?) throws
        -> PrepareResult
    {"""
    if anchor not in text:
        raise SystemExit(f"Anchor for prepareAudioTranscription not found in {gemma4} — upstream changed.")
    text = text.replace(anchor, insert, 1)

    gemma4.write_text(text)
    return f"patched: {gemma4}"


def main() -> None:
    repo = _repo_root()
    paths = _collect_gemma4_paths(repo)
    if not paths:
        print(
            "No MLXVLM Gemma4.swift checkouts found — run `swift build` in FlmMLXRuntime "
            "or `flutter build macos` once, then re-run this script.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    for p in paths:
        print(_patch_one(p))


if __name__ == "__main__":
    main()
