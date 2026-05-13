#!/usr/bin/env python3
"""
Long-lived MLX-Audio TTS worker for low-latency streaming.

Protocol (newline-delimited JSON on stdin/stdout):
  1) First line: worker config, e.g.
     {"model_path":"/path/to/qwen3-tts","voice":"Ryan","lang_code":"english",
      "speed":1.0,"streaming_interval":0.35,"temperature":0.7,"verbose":false}
  2) Each next line: segment to synthesize:
     {"text":"Hello."}
  3) Stdin EOF: worker exits after finishing queued work.

For each segment, runs model.generate(stream=True). Each streamed audio chunk is
written to a temp .wav and emitted as:
  {"wav":"/tmp/..","sample_rate":24000,"segment":0}

On fatal error:
  {"error":"..."}

Reference audio (Qwen clone) is optional:
  {"ref_audio":"/path","ref_text":"..."} in the config line only.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import traceback

import numpy as np


def _emit(obj: object) -> None:
    print(json.dumps(obj), flush=True)


def main() -> int:
    try:
        from mlx_audio.audio_io import write as audio_write
        from mlx_audio.tts.utils import load_model
    except ImportError as e:
        _emit({"error": f"mlx_audio import failed: {e}"})
        return 2

    try:
        cfg_line = sys.stdin.readline()
        if not cfg_line:
            return 0
        cfg = json.loads(cfg_line)
    except json.JSONDecodeError as e:
        _emit({"error": f"invalid config json: {e}"})
        return 2

    model_path = cfg.get("model_path")
    if not model_path:
        _emit({"error": "model_path is required"})
        return 2

    try:
        model = load_model(model_path=model_path)
    except Exception as e:  # pylint: disable=broad-exception-caught
        _emit({"error": f"load_model failed: {e}"})
        return 2

    voice = cfg.get("voice", "Ryan")
    lang_code = cfg.get("lang_code") or "english"
    if lang_code == "auto":
        lang_code = "english"
    speed = float(cfg.get("speed", 1.0))
    streaming_interval = float(cfg.get("streaming_interval", 0.35))
    temperature = float(cfg.get("temperature", 0.7))
    verbose = bool(cfg.get("verbose", False))
    max_tokens = int(cfg.get("max_tokens", 1200))
    instruct = cfg.get("instruct")
    ref_audio_path = cfg.get("ref_audio")
    ref_text = cfg.get("ref_text")

    ref_audio = None
    if ref_audio_path and ref_text:
        try:
            from mlx_audio.utils import load_audio

            normalize = False
            if hasattr(model, "model_type") and model.model_type == "spark":
                normalize = True
            if not os.path.exists(ref_audio_path):
                _emit({"error": f"ref_audio missing: {ref_audio_path}"})
                return 2
            ref_audio = load_audio(
                ref_audio_path, sample_rate=model.sample_rate, volume_normalize=normalize
            )
        except Exception as e:  # pylint: disable=broad-exception-caught
            _emit({"error": f"ref_audio load failed: {e}"})
            return 2

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            _emit({"error": f"invalid segment json: {e}"})
            return 2

        text = (msg.get("text") or "").strip()
        if not text:
            continue

        gen_kwargs = dict(
            text=text,
            voice=voice,
            speed=speed,
            lang_code=lang_code,
            stream=True,
            streaming_interval=streaming_interval,
            verbose=verbose,
            temperature=temperature,
            max_tokens=max_tokens,
            ref_audio=ref_audio,
            ref_text=ref_text,
        )
        if instruct:
            gen_kwargs["instruct"] = instruct

        try:
            for i, result in enumerate(model.generate(**gen_kwargs)):
                fd, path = tempfile.mkstemp(prefix="flm_tts_stream_", suffix=".wav")
                os.close(fd)
                audio_write(
                    path, np.array(result.audio), result.sample_rate, format="wav"
                )
                _emit(
                    {
                        "wav": path,
                        "sample_rate": int(result.sample_rate),
                        "segment": i,
                    }
                )
        except Exception as e:  # pylint: disable=broad-exception-caught
            _emit({"error": f"generate failed: {e}\n{traceback.format_exc()}"})
            return 2

    _emit({"done": True})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
