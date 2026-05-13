#!/usr/bin/env python3
"""Три последовательных синтеза Qwen3-TTS через Python `mlx_audio` (как в Studio fallback).

Пишет WAV-файлы и подробный run.log в одну папку — можно слушать и сравнивать голос/просодию.

Примеры::

    export MLX_PYTHON="$HOME/.venvs/mlx/bin/python"   # где стоит mlx_audio

    python3 tools/qwen3_tts_triple_cli.py \\
        --model "$HOME/Library/Containers/com.example.localModelsStudio/Data/.../models/qwen3-tts-12hz-0.6b-base-4bit"

    python3 tools/qwen3_tts_triple_cli.py --discover

Папка вывода по умолчанию: ``<корень репозитория>/out/qwen3_tts_triple_<UTC-время>/``
(корень — каталог, где лежит ``tools/``; можно задать ``--out``).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _default_studio_models_dir() -> Path:
    return (
        Path.home()
        / "Library/Containers/com.example.localModelsStudio/Data/Library/Application Support/flutter_local_models/models"
    )


def _mlx_python() -> str:
    return os.environ.get("MLX_PYTHON") or str(Path.home() / ".venvs/mlx/bin/python")


def _load_installed_model_dirs(models_dir: Path) -> list[tuple[str, Path]]:
    rows: list[tuple[str, Path]] = []
    if not models_dir.is_dir():
        return rows
    for meta in sorted(models_dir.glob("*/.flutter_local_model.json")):
        try:
            data = json.loads(meta.read_text())
            mid = str(data.get("manifest", {}).get("id", ""))
            rows.append((mid, meta.parent))
        except (OSError, json.JSONDecodeError, KeyError):
            continue
    return rows


def _discover_qwen3_tts(models_dir: Path) -> Path | None:
    for mid, directory in _load_installed_model_dirs(models_dir):
        if "qwen3" in mid.lower() and "tts" in mid.lower():
            return directory
    return None


def _log(fp, msg: str) -> None:
    line = msg.rstrip() + "\n"
    fp.write(line)
    fp.flush()
    print(line, end="")


def _run_tts(
    *,
    py: str,
    model_dir: Path,
    out_dir: Path,
    text: str,
    file_prefix: str,
    voice: str,
    lang_code: str,
    temperature: float,
    top_p: float,
    top_k: int,
    repetition_penalty: float,
    max_tokens: int,
    log_fp,
) -> tuple[int, str, str]:
    cmd = [
        py,
        "-m",
        "mlx_audio.tts.generate",
        "--model",
        str(model_dir),
        "--text",
        text,
        "--output_path",
        str(out_dir),
        "--file_prefix",
        file_prefix,
        "--audio_format",
        "wav",
        "--voice",
        voice,
        "--lang_code",
        lang_code,
        "--temperature",
        str(temperature),
        "--top_p",
        str(top_p),
        "--top_k",
        str(top_k),
        "--repetition_penalty",
        str(repetition_penalty),
        "--max_tokens",
        str(max_tokens),
        "--join_audio",
    ]
    _log(log_fp, f"CMD {' '.join(cmd)!r}")
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=600,
    )
    _log(log_fp, f"exit={proc.returncode}")
    if proc.stdout:
        _log(log_fp, "--- stdout ---\n" + proc.stdout)
    if proc.stderr:
        _log(log_fp, "--- stderr ---\n" + proc.stderr)
    return proc.returncode, proc.stdout, proc.stderr


def main() -> int:
    parser = argparse.ArgumentParser(description="Qwen3-TTS triple run (mlx_audio CLI).")
    parser.add_argument(
        "--model",
        type=Path,
        help="Каталог установленной Qwen3-TTS (с config.json).",
    )
    parser.add_argument(
        "--discover",
        action="store_true",
        help=f"Взыскать первую qwen3*tts* в {_default_studio_models_dir()}",
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        default=_default_studio_models_dir(),
        help="Корень installed models Studio (для --discover).",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="Каталог вывода (по умолчанию out/qwen3_tts_triple_<utc> под корнем репо).",
    )
    parser.add_argument("--voice", default="Vivian")
    parser.add_argument("--lang_code", default="english")
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--top_p", type=float, default=1.0)
    parser.add_argument("--top_k", type=int, default=0)
    parser.add_argument("--repetition_penalty", type=float, default=1.0)
    parser.add_argument("--max_tokens", type=int, default=4096)
    args = parser.parse_args()

    model_dir = args.model
    if args.discover:
        found = _discover_qwen3_tts(args.models_dir)
        if found is None:
            print(
                f"No qwen3 TTS under {args.models_dir} (.flutter_local_model.json).",
                file=sys.stderr,
            )
            return 2
        model_dir = found
    if model_dir is None:
        print("Нужен --model ПУТЬ или флаг --discover.", file=sys.stderr)
        return 64
    model_dir = model_dir.resolve()
    if not model_dir.is_dir():
        print(f"Not a directory: {model_dir}", file=sys.stderr)
        return 66

    root = _repo_root()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = args.out
    if out_dir is None:
        out_dir = root / "out" / f"qwen3_tts_triple_{stamp}"
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    py = _mlx_python()
    phrases: list[tuple[str, str]] = [
        ("01_hello", "hello"),
        ("02_how_are_you", "how are you"),
        ("03_whether", "what is whether today"),
    ]

    log_path = out_dir / "run.log"
    with log_path.open("w", encoding="utf-8") as log_fp:
        _log(log_fp, f"utc={stamp}")
        _log(log_fp, f"model_dir={model_dir}")
        _log(log_fp, f"mlx_python={py}")
        _log(log_fp, f"voice={args.voice!r} lang_code={args.lang_code!r}")
        _log(
            log_fp,
            f"sample params: temp={args.temperature} top_p={args.top_p} top_k={args.top_k} "
            f"rep_pen={args.repetition_penalty} max_tokens={args.max_tokens}",
        )
        _log(log_fp, f"output_dir={out_dir}")
        _log(log_fp, "")
        failures = 0
        for prefix, text in phrases:
            _log(log_fp, f"===== {prefix} text={text!r} =====")
            code, _, _ = _run_tts(
                py=py,
                model_dir=model_dir,
                out_dir=out_dir,
                text=text,
                file_prefix=prefix,
                voice=args.voice,
                lang_code=args.lang_code,
                temperature=args.temperature,
                top_p=args.top_p,
                top_k=args.top_k,
                repetition_penalty=args.repetition_penalty,
                max_tokens=args.max_tokens,
                log_fp=log_fp,
            )
            if code != 0:
                failures += 1
            _log(log_fp, "")

    wavs = sorted(out_dir.glob("*.wav"))
    summary_path = out_dir / "files.txt"
    summary_path.write_text(
        "\n".join(str(p.name) for p in wavs) + "\n",
        encoding="utf-8",
    )

    print(f"OK: лог {log_path}")
    print(f"OK: список wav → {summary_path}")
    for p in wavs:
        print(f"  wav: {p}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
