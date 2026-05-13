#!/usr/bin/env python3
"""
Gemma 4 ASR (Automatic Speech Recognition) via MLX.

Loads the Gemma4 audio tower weights from a local model directory and runs
speech-to-text inference entirely on Apple Silicon using MLX.  No PyTorch or
internet connection required at inference time.

Usage:
    python3 gemma4_asr.py --model /path/to/gemma4-e2b-it-4bit \
                          --audio /path/to/recording.m4a \
                          [--language en] [--prompt "Transcribe the speech."]
"""

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile

import mlx.core as mx
import mlx.nn as nn
import numpy as np

# ---------------------------------------------------------------------------
# Audio loading + resampling (numpy/scipy only — no PyTorch)
# ---------------------------------------------------------------------------

def _load_audio_numpy(path: str, target_sr: int = 16_000) -> np.ndarray:
    """Load an audio file and return a mono float32 waveform at *target_sr* Hz."""
    # Convert to WAV with ffmpeg (always available on macOS), then load with wave.
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name

    try:
        subprocess.run(
            [
                "ffmpeg", "-y", "-i", path,
                "-ac", "1",                 # mono
                "-ar", str(target_sr),      # target sample rate
                "-sample_fmt", "s16",       # signed 16-bit
                "-loglevel", "error",
                wav_path,
            ],
            check=True,
            capture_output=True,
        )
        import wave, struct
        with wave.open(wav_path, "rb") as wf:
            n_frames = wf.getnframes()
            raw = wf.readframes(n_frames)
            samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
        return samples
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Mel spectrogram — matches Gemma4AudioFeatureExtractor exactly
# ---------------------------------------------------------------------------

def _mel_spectrogram(
    waveform: np.ndarray,
    sample_rate: int = 16_000,
) -> np.ndarray:
    """Compute log-mel spectrogram using Gemma4AudioFeatureExtractor (pure numpy)."""
    from transformers.models.gemma4.feature_extraction_gemma4 import Gemma4AudioFeatureExtractor

    fe = Gemma4AudioFeatureExtractor(sampling_rate=sample_rate)
    # Returns (time_frames, n_mels) float32
    mel, _ = fe._extract_spectrogram(
        waveform.astype(np.float32),
        np.ones(len(waveform), dtype=np.float32),
    )
    return mel.astype(np.float32)


# ---------------------------------------------------------------------------
# MLX helpers
# ---------------------------------------------------------------------------

def _rms_norm(x: mx.array, weight: mx.array | None, eps: float = 1e-6) -> mx.array:
    ms = mx.mean(x ** 2, axis=-1, keepdims=True)
    normed = x * mx.rsqrt(ms + eps)
    if weight is not None:
        normed = normed * weight
    return normed


def _clipped_linear(x: mx.array, w: mx.array, in_min=None, in_max=None, out_min=None, out_max=None) -> mx.array:
    if in_min is not None:
        x = mx.clip(x, in_min.item(), in_max.item())
    y = x @ w.T
    if out_min is not None:
        y = mx.clip(y, out_min.item(), out_max.item())
    return y


def _feed_forward(x: mx.array, W: dict, clip: float = 1e10) -> mx.array:
    """Gemma4AudioFeedForward forward pass (0.5 residual)."""
    gc = min(clip, float(np.finfo(np.float32).max))
    residual = x
    x = mx.clip(x, -gc, gc)
    x = _rms_norm(x, W["pre_layer_norm.weight"])
    x = _clipped_linear(
        x, W["ffw_layer_1.linear.weight"],
        W.get("ffw_layer_1.input_min"), W.get("ffw_layer_1.input_max"),
        W.get("ffw_layer_1.output_min"), W.get("ffw_layer_1.output_max"),
    )
    x = nn.silu(x)  # hidden_act = silu
    x = _clipped_linear(
        x, W["ffw_layer_2.linear.weight"],
        W.get("ffw_layer_2.input_min"), W.get("ffw_layer_2.input_max"),
        W.get("ffw_layer_2.output_min"), W.get("ffw_layer_2.output_max"),
    )
    x = mx.clip(x, -gc, gc)
    x = _rms_norm(x, W["post_layer_norm.weight"])
    return x * 0.5 + residual * 0.5


def _rel_pos_enc(hidden_size: int, context_size: int, dtype) -> mx.array:
    """Sinusoidal relative positional encoding matching Gemma4AudioRelPositionalEncoding."""
    num_timescales = hidden_size // 2
    log_timescale_increment = math.log(10000.0) / max(num_timescales - 1, 1)
    inv_timescales = np.exp(-np.arange(num_timescales, dtype=np.float32) * log_timescale_increment)

    # position_ids counts down from context_size//2 to 0
    position_ids = np.arange(context_size // 2, -1, -1, dtype=np.float32)[:, None]
    scaled = position_ids * inv_timescales[None, :]
    pos_embed = np.concatenate([np.sin(scaled), np.cos(scaled)], axis=-1)
    pos_embed = pos_embed[None, :, :]  # (1, context_size//2 + 1, hidden_size)
    return mx.array(pos_embed, dtype=dtype)


def _chunked_attention(
    hidden: mx.array,
    W: dict,
    position_embeddings: mx.array,
    chunk_size: int,
    max_past: int,
    num_heads: int,
    head_dim: int,
    softcap: float,
    clip: float,
) -> mx.array:
    """Gemma4AudioAttention forward (chunked local attention with relative position bias)."""
    B, T, D = hidden.shape
    gc = min(clip, float(np.finfo(np.float32).max))

    q_scale = (head_dim ** -0.5) / math.log(2)
    k_scale = math.log(1 + math.e) / math.log(2)

    context_size = chunk_size + max_past  # max_future=0

    per_dim_scale = W["self_attn.per_dim_scale"]  # (head_dim,)

    # Project
    q = _clipped_linear(hidden, W["self_attn.q_proj.linear.weight"],
                        W.get("self_attn.q_proj.input_min"), W.get("self_attn.q_proj.input_max"),
                        W.get("self_attn.q_proj.output_min"), W.get("self_attn.q_proj.output_max"))
    k = _clipped_linear(hidden, W["self_attn.k_proj.linear.weight"],
                        W.get("self_attn.k_proj.input_min"), W.get("self_attn.k_proj.input_max"),
                        W.get("self_attn.k_proj.output_min"), W.get("self_attn.k_proj.output_max"))
    v = _clipped_linear(hidden, W["self_attn.v_proj.linear.weight"],
                        W.get("self_attn.v_proj.input_min"), W.get("self_attn.v_proj.input_max"),
                        W.get("self_attn.v_proj.output_min"), W.get("self_attn.v_proj.output_max"))

    # Cast to float32 for attention computation
    q = q.astype(mx.float32).reshape(B, T, num_heads, head_dim)
    k = k.astype(mx.float32).reshape(B, T, num_heads, head_dim)
    v = v.astype(mx.float32).reshape(B, T, num_heads, head_dim)

    q = q * q_scale * nn.softplus(per_dim_scale).astype(mx.float32)
    k = k * k_scale

    # Pad T to multiple of chunk_size
    num_blocks = (T + chunk_size - 1) // chunk_size
    pad_len = num_blocks * chunk_size - T

    def pad_time(x, pad_val=0.0):
        if pad_len > 0:
            pad_shape = list(x.shape)
            pad_shape[1] = pad_len
            return mx.concatenate([x, mx.zeros(pad_shape, dtype=x.dtype)], axis=1)
        return x

    q_pad = pad_time(q)  # (B, num_blocks*chunk_size, H, D)
    k_pad = pad_time(k)
    v_pad = pad_time(v)

    # Split Q into blocks: (B, num_blocks, chunk_size, H, D)
    q_blocks = q_pad.reshape(B, num_blocks, chunk_size, num_heads, head_dim)

    # Extract context windows for K/V with left padding of max_past
    # Pad left of sequence with max_past zeros, then extract sliding windows
    left_pad = mx.zeros((B, max_past, num_heads, head_dim), dtype=k.dtype)
    # Also add chunk_size-1 right padding to align the last block
    right_pad = mx.zeros((B, chunk_size - 1, num_heads, head_dim), dtype=k.dtype)
    k_padded = mx.concatenate([left_pad, k_pad, right_pad], axis=1)
    v_padded = mx.concatenate([left_pad, v_pad, right_pad], axis=1)

    # Extract (num_blocks, context_size) windows
    # For block i: k[i*chunk_size : i*chunk_size + context_size]
    k_ctx_list = []
    v_ctx_list = []
    for i in range(num_blocks):
        start = i * chunk_size
        k_ctx_list.append(k_padded[:, start:start + context_size, :, :])
        v_ctx_list.append(v_padded[:, start:start + context_size, :, :])

    k_ctx = mx.stack(k_ctx_list, axis=1)  # (B, num_blocks, context_size, H, D)
    v_ctx = mx.stack(v_ctx_list, axis=1)

    # Relative position embeddings
    rel_k = (position_embeddings @ W["self_attn.relative_k_proj.weight"].T)  # (1, ctx//2+1, H*D)
    rel_k = rel_k.reshape(-1, num_heads, head_dim)  # (ctx//2+1, H, D)

    # Compute attention scores
    # matrix_ac: Q @ K^T  → (B, H, num_blocks, chunk_size, context_size)
    q_t = q_blocks.transpose(0, 3, 1, 2, 4)  # (B, H, num_blocks, chunk_size, D)
    k_t = k_ctx.transpose(0, 3, 1, 4, 2)     # (B, H, num_blocks, D, context_size)
    matrix_ac = q_t @ k_t

    # matrix_bd: relative position scores
    q_flat = q_t.reshape(B, num_heads, -1, head_dim)  # (B, H, num_blocks*chunk_size, D)
    rel_k_t = rel_k.transpose(1, 2, 0)  # (H, D, ctx//2+1)
    matrix_bd_flat = q_flat @ rel_k_t   # (B, H, num_blocks*chunk_size, ctx//2+1)
    matrix_bd = matrix_bd_flat.reshape(B, num_heads, num_blocks, chunk_size, -1)

    # _rel_shift: adjust relative positions
    pos_len = matrix_bd.shape[-1]
    pad_size = context_size + 1 - pos_len
    if pad_size > 0:
        pad_bd = mx.zeros((*matrix_bd.shape[:-1], pad_size), dtype=matrix_bd.dtype)
        matrix_bd = mx.concatenate([matrix_bd, pad_bd], axis=-1)
    matrix_bd = matrix_bd.reshape(B, num_heads, num_blocks, chunk_size * (context_size + 1))
    matrix_bd = matrix_bd[..., :chunk_size * context_size]
    matrix_bd = matrix_bd.reshape(B, num_heads, num_blocks, chunk_size, context_size)

    attn_weights = matrix_ac + matrix_bd

    # Softcap
    attn_weights = mx.tanh(attn_weights / softcap) * softcap

    # Softmax
    attn_weights = mx.softmax(attn_weights.astype(mx.float32), axis=-1).astype(v.dtype)

    # Weighted sum: (B, H, num_blocks, chunk_size, D)
    v_t = v_ctx.transpose(0, 3, 1, 2, 4)  # (B, H, num_blocks, context_size, D)
    out = attn_weights @ v_t              # (B, H, num_blocks, chunk_size, D)

    # Reshape back to (B, T, D)
    out = out.transpose(0, 2, 3, 1, 4)   # (B, num_blocks, chunk_size, H, D)
    out = out.reshape(B, num_blocks * chunk_size, num_heads * head_dim)
    out = out[:, :T, :]

    # Post projection (cast back to model dtype)
    out = out.astype(hidden.dtype)
    out = _clipped_linear(out, W["self_attn.post.linear.weight"],
                         W.get("self_attn.post.input_min"), W.get("self_attn.post.input_max"),
                         W.get("self_attn.post.output_min"), W.get("self_attn.post.output_max"))
    return out


def _light_conv1d(x: mx.array, W: dict, kernel_size: int, clip: float) -> mx.array:
    """Gemma4AudioLightConv1d forward."""
    gc = min(clip, float(np.finfo(np.float32).max))
    residual = x

    x = _rms_norm(x, W["lconv1d.pre_layer_norm.weight"])

    # linear_start with GLU (hidden_size*2 → split in half)
    x = _clipped_linear(x, W["lconv1d.linear_start.linear.weight"],
                        W.get("lconv1d.linear_start.input_min"), W.get("lconv1d.linear_start.input_max"),
                        W.get("lconv1d.linear_start.output_min"), W.get("lconv1d.linear_start.output_max"))
    # GLU: split along last axis
    half = x.shape[-1] // 2
    x = x[..., :half] * mx.sigmoid(x[..., half:])

    # Causal depthwise conv1d: weight shape (out_channels, kernel_size, 1) = (H, K, 1)
    # Causal: pad (kernel_size-1) on the left
    dw = W["lconv1d.depthwise_conv1d.weight"]  # (H, K, 1) → need (1, H, K, 1) for conv
    B, T, H = x.shape
    # Causal padding: add kernel_size-1 zeros at the start
    pad = mx.zeros((B, kernel_size - 1, H), dtype=x.dtype)
    x_padded = mx.concatenate([pad, x], axis=1)  # (B, T+K-1, H)

    # Depthwise conv: process each channel independently
    # dw: (H, K, 1) - each channel has a separate kernel of size K
    # We process as: for each channel c, convolve x_padded[:, :, c] with dw[c, :, 0]
    # Efficient vectorized approach: use the conv kernel as a matrix multiplication
    # x_padded: (B, T+K-1, H) → unfold: (B, T, K, H) → multiply by dw
    k = kernel_size
    x_unfolded = mx.stack([x_padded[:, i:i+k, :] for i in range(T)], axis=1)  # (B, T, K, H)
    # dw: (H, K, 1) → (H, K) → (K, H)
    dw_2d = dw[:, :, 0].T  # (K, H)
    # Multiply and sum over K: (B, T, K, H) * (K, H) → sum over K
    x = (x_unfolded * dw_2d[None, None, :, :]).sum(axis=2)  # (B, T, H)

    x = mx.clip(x, -gc, gc)
    x = _rms_norm(x, W["lconv1d.conv_norm.weight"])
    x = nn.silu(x)

    x = _clipped_linear(x, W["lconv1d.linear_end.linear.weight"],
                        W.get("lconv1d.linear_end.input_min"), W.get("lconv1d.linear_end.input_max"),
                        W.get("lconv1d.linear_end.output_min"), W.get("lconv1d.linear_end.output_max"))
    return x + residual


def _audio_layer(x: mx.array, layer_weights: dict, cfg: dict, pos_emb: mx.array) -> mx.array:
    """One Gemma4AudioLayer forward."""
    clip = min(cfg["gradient_clipping"], float(np.finfo(np.float32).max))
    chunk_size = cfg["attention_chunk_size"]
    max_past = cfg["attention_context_left"] - 1
    num_heads = cfg["num_attention_heads"]
    hidden_size = cfg["hidden_size"]
    head_dim = hidden_size // num_heads
    softcap = cfg["attention_logit_cap"]
    kernel_size = cfg["conv_kernel_size"]

    x = _feed_forward(x, {k[len("feed_forward1."):]: v for k, v in layer_weights.items() if k.startswith("feed_forward1.")})

    residual = x
    x = mx.clip(x, -clip, clip)
    x = _rms_norm(x, layer_weights["norm_pre_attn.weight"])

    x = _chunked_attention(x, layer_weights, pos_emb, chunk_size, max_past, num_heads, head_dim, softcap, clip)

    x = mx.clip(x, -clip, clip)
    x = _rms_norm(x, layer_weights["norm_post_attn.weight"])
    x = x + residual

    x = _light_conv1d(x, {k: v for k, v in layer_weights.items()}, kernel_size, clip)

    x = _feed_forward(x, {k[len("feed_forward2."):]: v for k, v in layer_weights.items() if k.startswith("feed_forward2.")})

    x = mx.clip(x, -clip, clip)
    x = _rms_norm(x, layer_weights["norm_out.weight"])
    return x


def _subsample_conv_projection(mel: mx.array, weights: dict) -> mx.array:
    """Gemma4AudioSubSampleConvProjection forward (bfloat16 Conv2D, stride 2x2)."""
    B, T, M = mel.shape
    # MLX conv2d expects BHWC: (B, T, mel_bins, 1)
    x = mel.reshape(B, T, M, 1)

    # Layer 0: Conv2d(1→128, kernel 3x3, stride 2x2, padding 1)
    w0 = weights["audio_tower.subsample_conv_projection.layer0.conv.weight"]  # (128, 3, 3, 1)
    norm0 = weights["audio_tower.subsample_conv_projection.layer0.norm.weight"]  # (128,)
    x = mx.conv2d(x, w0, stride=(2, 2), padding=(1, 1))  # (B, T/2, M/2, 128)
    x = _rms_norm(x, norm0)
    x = nn.relu(x)

    # Layer 1: Conv2d(128→32, kernel 3x3, stride 2x2, padding 1)
    w1 = weights["audio_tower.subsample_conv_projection.layer1.conv.weight"]  # (32, 3, 3, 128)
    norm1 = weights["audio_tower.subsample_conv_projection.layer1.norm.weight"]  # (32,)
    x = mx.conv2d(x, w1, stride=(2, 2), padding=(1, 1))  # (B, T/4, M/4, 32)
    x = _rms_norm(x, norm1)
    x = nn.relu(x)

    # Flatten last two spatial/channel dims: (B, T/4, M/4 * 32) = (B, T/4, 1024)
    B2, T2, W2, C2 = x.shape
    x = x.reshape(B2, T2, W2 * C2)

    # Linear projection (1024 → 1024)
    w_proj = weights["audio_tower.subsample_conv_projection.input_proj_linear.weight"]  # (1024, 1024)
    x = x @ w_proj.T
    return x


def _embed_audio(hidden: mx.array, weights: dict) -> mx.array:
    """embed_audio: RMSNorm (no scale) + 4-bit quantized Linear."""
    # RMSNorm without scale
    x = _rms_norm(hidden, None)

    # Dequantize and apply embedding projection
    # Weights stored as MLX group-quantized 4-bit:
    #   weight: (out, in//8) uint32
    #   scales: (out, in//group_size) bfloat16
    #   biases: (out, in//group_size) bfloat16
    w = weights["embed_audio.embedding_projection.weight"]
    scales = weights["embed_audio.embedding_projection.scales"]
    biases = weights["embed_audio.embedding_projection.biases"]

    # Determine group_size from scales shape
    out_features = w.shape[0]
    n_groups = scales.shape[1]
    bits = 4
    in_features = w.shape[1] * (32 // bits)
    group_size = in_features // n_groups

    w_fp = mx.dequantize(w, scales, biases, group_size=group_size, bits=bits)  # (out, in)
    x = x @ w_fp.T
    return x


# ---------------------------------------------------------------------------
# Full Gemma4 audio tower
# ---------------------------------------------------------------------------

def encode_audio(mel: np.ndarray, weights: dict, config: dict) -> mx.array:
    """
    Run the full Gemma4 audio encoder and return audio embeddings.

    Args:
        mel: (time_frames, n_mels) float32 numpy array
        weights: dict from mx.load(model.safetensors)
        config: dict from config.json

    Returns:
        embeddings: (1, num_audio_tokens, text_hidden_size) mx.array bfloat16
    """
    dtype = mx.bfloat16
    audio_cfg = config["audio_config"]
    hidden_size = audio_cfg["hidden_size"]
    num_layers = audio_cfg["num_hidden_layers"]
    chunk_size = audio_cfg["attention_chunk_size"]
    context_left = audio_cfg["attention_context_left"]
    context_right = audio_cfg["attention_context_right"]
    context_size = chunk_size + context_left - 1 + context_right

    # (1, T, 128) bfloat16
    mel_mx = mx.array(mel[None, :, :], dtype=dtype)

    # 1. Subsampling conv projection → (1, T/4, 1024)
    hidden = _subsample_conv_projection(mel_mx, weights)

    # 2. Relative positional encoding
    pos_emb = _rel_pos_enc(hidden_size, context_size, dtype)  # (1, ctx//2+1, hidden_size)

    # 3. 12 Conformer layers
    for layer_idx in range(num_layers):
        prefix = f"audio_tower.layers.{layer_idx}."
        layer_w = {k[len(prefix):]: v for k, v in weights.items() if k.startswith(prefix)}
        hidden = _audio_layer(hidden, layer_w, audio_cfg, pos_emb)
        mx.eval(hidden)  # force evaluation to avoid OOM

    # 4. Output projection (1024 → 1536)
    out_w = weights["audio_tower.output_proj.weight"]
    out_b = weights["audio_tower.output_proj.bias"]
    hidden = hidden @ out_w.T + out_b

    # 5. embed_audio: RMSNorm + 4-bit Linear (1536 → text_hidden_size)
    embeddings = _embed_audio(hidden, weights)
    return embeddings


# ---------------------------------------------------------------------------
# MLX-LM generation with audio token injection
# ---------------------------------------------------------------------------

def transcribe(
    model_path: str,
    audio_path: str,
    language: str = "",
    max_tokens: int = 256,
) -> str:
    """Full Gemma4 ASR: encode audio → inject into LM → generate transcript."""
    from pathlib import Path
    from mlx_lm.utils import load_model
    from mlx_lm import tokenizer_utils
    from mlx_lm.models.cache import make_prompt_cache

    model_dir = Path(model_path)

    print(f"[gemma4_asr] Loading LM (strict=False)...", file=sys.stderr)
    model, _ = load_model(model_dir, lazy=True, strict=False)
    mx.eval(model.parameters())

    tokenizer = tokenizer_utils.TokenizerWrapper(
        tokenizer_utils.AutoTokenizer.from_pretrained(str(model_dir), trust_remote_code=True)
    )

    # Load ALL weights (including audio_tower) separately
    print("[gemma4_asr] Loading audio tower weights...", file=sys.stderr)
    weights_path = str(model_dir / "model.safetensors")
    all_weights = mx.load(weights_path, return_metadata=False)

    with open(model_dir / "config.json") as f:
        config = json.load(f)

    audio_token_id: int = config.get("audio_token_id", 258_881)
    pad_token_id: int = config.get("text_config", {}).get("pad_token_id", 0)

    # Build ASR system prompt
    if language:
        prompt_text = (
            f"Transcribe the following speech segment in {language} into {language} text. "
            "Output only the transcription, no extra text."
        )
    else:
        prompt_text = (
            "Transcribe the following speech segment in its original language. "
            "Output only the transcription, no extra text."
        )

    # Process audio
    print(f"[gemma4_asr] Loading audio: {audio_path}", file=sys.stderr)
    waveform = _load_audio_numpy(audio_path, target_sr=16_000)
    if len(waveform) > 30 * 16_000:
        waveform = waveform[:30 * 16_000]

    print("[gemma4_asr] Computing mel spectrogram...", file=sys.stderr)
    mel = _mel_spectrogram(waveform)

    print("[gemma4_asr] Running audio encoder...", file=sys.stderr)
    audio_embeds = encode_audio(mel, all_weights, config)  # (1, N_audio, D)
    mx.eval(audio_embeds)
    n_audio = audio_embeds.shape[1]
    print(f"[gemma4_asr] Audio → {n_audio} tokens", file=sys.stderr)

    eos_id = tokenizer.eos_token_id or 1

    # Build chat prompt with audio tokens embedded in the user message.
    # Use enable_thinking=False so the model outputs just the transcription.
    audio_str = "<|audio|>" * n_audio
    user_content = f"{prompt_text}\n{audio_str}"
    messages = [{"role": "user", "content": user_content}]
    if hasattr(tokenizer, "apply_chat_template"):
        try:
            token_ids: list[int] = tokenizer.apply_chat_template(
                messages,
                tokenize=True,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        except TypeError:
            token_ids = tokenizer.apply_chat_template(
                messages, tokenize=True, add_generation_prompt=True
            )
    else:
        token_ids = tokenizer.encode(user_content)

    input_ids = mx.array(token_ids)  # (T,)
    T = len(token_ids)
    # MLX-LM builds per-layer embeddings from `inputs`; audio slots must use PAD
    # (see HF Gemma4 llm_input_ids[multimodal_mask] = pad_token_id) — not raw audio_token_id.
    llm_input_ids = mx.array([pad_token_id if t == audio_token_id else t for t in token_ids])

    # Build combined embeddings: text at most positions, audio at audio_token positions
    # The language_model expects: model.language_model.model.embed_tokens
    embed_tokens = model.language_model.model.embed_tokens

    # Replace audio positions with PAD (for embed_tokens), then overwrite with audio
    pad_ids = [pad_token_id if t == audio_token_id else t for t in token_ids]
    pad_id_arr = mx.array(pad_ids)
    text_embeds = embed_tokens(pad_id_arr[None])  # (1, T, D)
    mx.eval(text_embeds)
    D = text_embeds.shape[-1]

    # Build combined: replace audio token positions with audio embeddings
    audio_positions = [i for i, t in enumerate(token_ids) if t == audio_token_id]
    n_use = min(len(audio_positions), n_audio)

    # Build row by row (seq len is a few hundred, totally fine)
    rows = []
    audio_idx = 0
    for i, tok in enumerate(token_ids):
        if tok == audio_token_id and audio_idx < n_use:
            rows.append(audio_embeds[0, audio_idx])
            audio_idx += 1
        else:
            rows.append(text_embeds[0, i])

    combined_embeds = mx.stack(rows, axis=0)[None]  # (1, T, D)
    mx.eval(combined_embeds)

    # Generation using KV cache
    print("[gemma4_asr] Generating transcription...", file=sys.stderr)
    cache = make_prompt_cache(model)

    # Prefill with combined embeddings
    logits = model(llm_input_ids[None], cache=cache, input_embeddings=combined_embeds)
    mx.eval(logits, cache)

    # Greedy decode
    next_id = int(mx.argmax(logits[0, -1, :]).item())
    output_ids = []

    for _ in range(max_tokens):
        if next_id == eos_id:
            break
        output_ids.append(next_id)

        tok_arr = mx.array([[next_id]])
        logits = model(tok_arr, cache=cache)
        mx.eval(logits, cache)
        next_id = int(mx.argmax(logits[0, -1, :]).item())

    transcript = tokenizer.decode(output_ids, skip_special_tokens=True).strip()
    return transcript


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Gemma4 ASR via MLX")
    parser.add_argument("--model", required=True, help="Path to installed Gemma4 model directory")
    parser.add_argument("--audio", required=True, help="Path to audio file (any ffmpeg-supported format)")
    parser.add_argument("--language", default="", help="Language code (e.g. 'en'). Empty = auto-detect.")
    parser.add_argument("--max-tokens", type=int, default=256, help="Max output tokens")
    args = parser.parse_args()

    transcript = transcribe(
        model_path=args.model,
        audio_path=args.audio,
        language=args.language,
        max_tokens=args.max_tokens,
    )
    print(transcript)


if __name__ == "__main__":
    main()
