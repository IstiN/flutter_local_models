#!/usr/bin/env python3
"""Демо тех же трёх фраз что `qwen3_tts_triple_cli.py`, но **без MLX / mlx_audio**.

Пишет валидные WAV через stdlib (`wave`): короткий синус с разной частотой на файл —
удобно проверить пайплайн плеера и сравнить «три разных файла» без нейросети.

Пример::

    python3 tools/qwen3_tts_triple_demo_cli.py
    python3 tools/qwen3_tts_triple_demo_cli.py --out /tmp/demo_tts

Самопроверка::

    python3 tools/qwen3_tts_triple_demo_cli.py --self-test
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


PHRASES: list[tuple[str, str, int]] = [
    ("01_hello", "hello", 440),
    ("02_how_are_you", "how are you", 523),
    ("03_whether", "what is whether today", 659),
]


def _write_tone_wav(path: Path, *, hz: int, seconds: float, sample_rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    n = int(sample_rate * seconds)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        for i in range(n):
            t = i / sample_rate
            s = int(0.25 * 32767 * math.sin(2 * math.pi * hz * t))
            w.writeframes(struct.pack("<h", s))


def run_demo(*, out_dir: Path, sample_rate: int, seconds: float, log_fp) -> None:
    def log(msg: str) -> None:
        log_fp.write(msg.rstrip() + "\n")
        log_fp.flush()
        print(msg)

    log(f"utc={datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}")
    log("mode=demo (no mlx_audio, synthetic sine WAV)")
    log(f"sample_rate={sample_rate} seconds={seconds}")
    log(f"output_dir={out_dir.resolve()}")
    log("")

    for prefix, text, hz in PHRASES:
        log(f"===== {prefix} text={text!r} hz={hz} =====")
        wav_path = out_dir / f"{prefix}.wav"
        _write_tone_wav(wav_path, hz=hz, seconds=seconds, sample_rate=sample_rate)
        log(f"wrote {wav_path} bytes={wav_path.stat().st_size}")
        log("")

    summary = out_dir / "files.txt"
    summary.write_text(
        "\n".join(f"{p}.wav" for p, _, _ in PHRASES) + "\n",
        encoding="utf-8",
    )
    log(f"files.txt → {summary}")


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="flm-tts-demo-") as td:
        p = Path(td)
        log_path = p / "run.log"
        with log_path.open("w", encoding="utf-8") as lf:
            run_demo(out_dir=p, sample_rate=24_000, seconds=0.15, log_fp=lf)
        for prefix, _, _ in PHRASES:
            wav = p / f"{prefix}.wav"
            if not wav.is_file() or wav.stat().st_size < 100:
                print(f"FAIL: missing or tiny {wav}", file=sys.stderr)
                return 1
        print("self-test OK:", td)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Triple WAV demo (no MLX), same labels as qwen3_tts_triple_cli.py",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="Каталог вывода (по умолчанию out/qwen3_tts_triple_demo_<utc>).",
    )
    parser.add_argument("--sample-rate", type=int, default=24_000)
    parser.add_argument(
        "--seconds",
        type=float,
        default=0.4,
        help="Длительность каждого тона.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Писать во временный каталог и проверить три WAV.",
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    root = _repo_root()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = args.out
    if out_dir is None:
        out_dir = root / "out" / f"qwen3_tts_triple_demo_{stamp}"
    out_dir = out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    log_path = out_dir / "run.log"
    with log_path.open("w", encoding="utf-8") as lf:
        run_demo(
            out_dir=out_dir,
            sample_rate=args.sample_rate,
            seconds=args.seconds,
            log_fp=lf,
        )

    print(f"OK: лог {log_path}")
    for prefix, _, _ in PHRASES:
        print(f"  wav: {out_dir / (prefix + '.wav')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
