#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


AUDIO_EXTENSIONS = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".aif", ".aiff", ".caf"}


@dataclass
class RunResult:
    status: str
    duration_seconds: float
    command: list[str]
    stdout: str
    stderr: str
    output: str = ""
    artifact_path: str | None = None
    artifact_bytes: int | None = None
    error: str | None = None
    speed_label: str = ""
    metrics: dict[str, float] | None = None


def default_models_dir() -> Path:
    return (
        Path.home()
        / "Library/Containers/com.example.localModelsStudio/Data/Library/Application Support/flutter_local_models/models"
    )


def load_installed_models(models_dir: Path) -> list[dict[str, Any]]:
    models: list[dict[str, Any]] = []
    for metadata_path in sorted(models_dir.glob("*/.flutter_local_model.json")):
        data = json.loads(metadata_path.read_text())
        manifest = data["manifest"]
        directory = metadata_path.parent
        models.append(
            {
                "id": manifest["id"],
                "display_name": manifest["displayName"],
                "runtime": manifest["runtimeAdapter"],
                "tasks": manifest["tasks"],
                "directory": str(directory),
                "size_bytes": directory_size(directory),
                "defaults": manifest.get("runtimeConfig", {}).get("defaultParameters") or {},
                "extra": manifest.get("runtimeConfig", {}).get("extra") or {},
                "voices": manifest.get("runtimeConfig", {}).get("voices") or [],
            }
        )
    return models


def directory_size(path: Path) -> int:
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            try:
                total += item.stat().st_size
            except OSError:
                pass
    return total


def run_command(command: list[str], timeout_seconds: int, cwd: Path | None = None) -> RunResult:
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
        elapsed = time.monotonic() - started
        status = "passed" if process.returncode == 0 else "failed"
        error = None if process.returncode == 0 else f"exit code {process.returncode}"
        return RunResult(
            status=status,
            duration_seconds=elapsed,
            command=command,
            stdout=ensure_text(stdout),
            stderr=ensure_text(stderr),
            error=error,
        )
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
        elapsed = time.monotonic() - started
        return RunResult(
            status="timeout",
            duration_seconds=elapsed,
            command=command,
            stdout=ensure_text(stdout),
            stderr=ensure_text(stderr),
            error=f"timed out after {timeout_seconds}s",
        )


def ensure_text(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def clean_generation_output(raw: str) -> str:
    text = raw.strip()
    marker = "<|turn>model"
    if marker in text:
        text = text.split(marker, 1)[1]
        text = text.split("==========", 1)[0]
    lines = []
    for line in text.splitlines():
        trimmed = line.strip()
        if not trimmed:
            continue
        if trimmed == "==========":
            continue
        if trimmed.startswith(("Files:", "Prompt:", "Generation:", "Peak memory:")):
            continue
        lines.append(trimmed)
    return "\n".join(lines).strip()


def tail(text: str, limit: int = 1600) -> str:
    clean = text.strip()
    if len(clean) <= limit:
        return clean
    return "…" + clean[-limit:]


def format_bytes(value: int | None) -> str:
    if value is None:
        return "—"
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(value)
    unit = units[0]
    for unit in units:
        if size < 1024 or unit == units[-1]:
            break
        size /= 1024
    if unit == "B":
        return f"{int(size)} B"
    return f"{size:.1f} {unit}".replace(".0 ", " ")


def find_audio_file(directory: Path, preferred_extension: str = ".wav") -> Path | None:
    files = [
        item
        for item in directory.rglob("*")
        if item.is_file() and item.suffix.lower() in AUDIO_EXTENSIONS and item.stat().st_size > 0
    ]
    if not files:
        return None
    preferred = preferred_extension.lower().lstrip(".")
    files.sort(
        key=lambda item: (
            0 if item.suffix.lower().lstrip(".") == preferred else 1,
            -item.stat().st_mtime,
        )
    )
    return files[0]


def audio_duration_seconds(path: Path) -> float | None:
    if path.suffix.lower() not in {".wav", ".wave"}:
        return None
    try:
        with wave.open(str(path), "rb") as audio:
            frames = audio.getnframes()
            rate = audio.getframerate()
            if rate <= 0:
                return None
            return frames / float(rate)
    except Exception:
        return None


def mlx_python() -> str:
    configured = os.environ.get("MLX_PYTHON")
    if configured:
        return configured
    return str(Path.home() / ".venvs/mlx/bin/python")


def model_supports_chat(model: dict[str, Any]) -> bool:
    return "chat" in model["tasks"] and model["runtime"] in {"mlx_lm", "mlx_vlm"}


def model_supports_tts(model: dict[str, Any]) -> bool:
    return "text_to_speech" in model["tasks"] and model["runtime"] == "mlx_audio"


def model_supports_asr(model: dict[str, Any]) -> bool:
    return "speech_to_text" in model["tasks"] and model["runtime"] == "mlx_audio"


def model_supports_image(model: dict[str, Any]) -> bool:
    return "image_generation" in model["tasks"] and model["runtime"] == "mflux"


def chat_command(model: dict[str, Any], prompt: str, max_tokens: int) -> list[str]:
    defaults = model["defaults"]
    temperature = defaults.get("temperature", defaults.get("temp", 0.3))
    if model["runtime"] == "mlx_lm":
        command = [
            mlx_python(),
            "-m",
            "mlx_lm",
            "generate",
            "--model",
            model["directory"],
            "--prompt",
            prompt,
            "--max-tokens",
            str(max_tokens),
            "--temp",
            str(temperature),
            "--verbose",
            "false",
        ]
        top_p = defaults.get("top_p", defaults.get("topP", 0.9))
        if top_p is not None:
            command += ["--top-p", str(top_p)]
        return command
    return [
        mlx_python(),
        "-m",
        "mlx_vlm",
        "generate",
        "--model",
        model["directory"],
        "--prompt",
        prompt,
        "--max-tokens",
        str(max_tokens),
        "--temperature",
        str(temperature),
    ]


def tts_command(
    model: dict[str, Any],
    text: str,
    output_dir: Path,
    reference_audio: Path | None,
    reference_text: str,
) -> list[str]:
    defaults = model["defaults"]
    audio_format = str(defaults.get("audio_format", "wav"))
    command = [
        mlx_python(),
        "-m",
        "mlx_audio.tts.generate",
        "--model",
        model["directory"],
        "--text",
        text,
        "--output_path",
        str(output_dir),
        "--file_prefix",
        f"speech-{int(time.time() * 1000)}",
        "--audio_format",
        audio_format,
    ]
    voice = str(defaults.get("voice", "")).strip()
    if not voice and model["voices"]:
        voice = str(model["voices"][0].get("id", "")).strip()
    if voice and voice != "default":
        command += ["--voice", voice]
    instruct = str(defaults.get("instruct", defaults.get("voice_prompt", ""))).strip()
    if instruct:
        command += ["--instruct", instruct]
    language = str(defaults.get("lang_code", defaults.get("language", ""))).strip()
    if language:
        command += ["--lang_code", language]
    speed = defaults.get("speed")
    if speed is not None:
        command += ["--speed", str(speed)]
    if model["extra"].get("qwen_tts_mode") == "base" and reference_audio is not None:
        command += ["--ref_audio", str(reference_audio), "--ref_text", reference_text]
    if defaults.get("join_audio", True):
        command += ["--join_audio"]
    return command


def asr_command(model: dict[str, Any], audio_path: Path, output_stem: Path) -> list[str]:
    return [
        mlx_python(),
        "-m",
        "mlx_audio.stt.generate",
        "--model",
        model["directory"],
        "--audio",
        str(audio_path),
        "--output-path",
        str(output_stem),
        "--format",
        "txt",
    ]


def mflux_executable(model: dict[str, Any]) -> str:
    identity = " ".join(
        [
            str(model["extra"].get("mflux_runner", "")),
            model["id"],
            model["display_name"],
            Path(model["directory"]).name,
        ]
    ).lower()
    if "qwen" in identity:
        command = "mflux-generate-qwen"
    elif "z-image-turbo" in identity:
        command = "mflux-generate-z-image-turbo"
    elif "z-image" in identity:
        command = "mflux-generate-z-image"
    else:
        command = "mflux-generate"
    return shutil.which(command) or str(Path.home() / ".local/bin" / command)


def image_command(model: dict[str, Any], output_path: Path, steps_cap: int) -> list[str]:
    defaults = model["defaults"]
    steps = min(int(defaults.get("steps", steps_cap)), steps_cap)
    width = min(int(defaults.get("width", 512)), 512)
    height = min(int(defaults.get("height", 512)), 512)
    guidance = defaults.get("guidance")
    command = [
        mflux_executable(model),
        "--model",
        model["directory"],
        "--prompt",
        "a tiny robot mascot reading benchmark results, clean app icon style",
        "--output",
        str(output_path),
        "--width",
        str(width),
        "--height",
        str(height),
        "--steps",
        str(steps),
    ]
    base_model = model["extra"].get("mflux_base_model")
    if base_model:
        command[3:3] = ["--base-model", str(base_model)]
    if guidance is not None:
        command += ["--guidance", str(guidance)]
    return command


def benchmark_chat(model: dict[str, Any], timeout_seconds: int, max_tokens: int) -> dict[str, Any]:
    prompts = [
        "Answer in one short English sentence: what does this local model benchmark measure?",
        "Ответь одним коротким русским предложением: зачем нужен локальный ИИ?",
    ]
    runs = []
    for prompt in prompts:
        result = run_command(chat_command(model, prompt, max_tokens), timeout_seconds)
        result.output = clean_generation_output(result.stdout)
        if result.status == "passed" and result.output and result.duration_seconds > 0:
            chars_per_second = len(result.output) / result.duration_seconds
            result.speed_label = f"{chars_per_second:.1f} chars/s"
            result.metrics = {"chars_per_second": round(chars_per_second, 3)}
        runs.append(result)
    return task_record(model, "chat", runs)


def benchmark_tts(
    model: dict[str, Any],
    timeout_seconds: int,
    reference_audio: Path | None,
    reference_text: str,
) -> dict[str, Any]:
    texts = [
        "Hello, this is a cold start speech benchmark.",
        "Second local speech synthesis run.",
    ]
    runs = []
    for text in texts:
        output_dir = Path(tempfile.mkdtemp(prefix=f"flm-bench-tts-{model['id']}-"))
        result = run_command(
            tts_command(model, text, output_dir, reference_audio, reference_text),
            timeout_seconds,
            cwd=output_dir,
        )
        audio = find_audio_file(output_dir, str(model["defaults"].get("audio_format", "wav")))
        if audio is not None:
            result.artifact_path = str(audio)
            result.artifact_bytes = audio.stat().st_size
            audio_seconds = audio_duration_seconds(audio)
            if audio_seconds is not None and result.duration_seconds > 0:
                realtime_factor = result.duration_seconds / audio_seconds
                result.speed_label = f"RTF {realtime_factor:.2f}"
                result.metrics = {
                    "audio_duration_seconds": round(audio_seconds, 3),
                    "realtime_factor": round(realtime_factor, 3),
                }
                result.output = (
                    f"{audio.name} ({format_bytes(result.artifact_bytes)}, "
                    f"{audio_seconds:.1f}s audio)"
                )
            else:
                result.output = f"{audio.name} ({format_bytes(result.artifact_bytes)})"
        elif result.status == "passed":
            result.status = "failed"
            result.error = "process exited successfully but produced no audio"
        runs.append(result)
    return task_record(model, "text_to_speech", runs)


def benchmark_asr(model: dict[str, Any], timeout_seconds: int, reference_audio: Path | None) -> dict[str, Any]:
    if reference_audio is None:
        return task_record(model, "speech_to_text", [], status="skipped", error="no reference audio available")
    output_dir = Path(tempfile.mkdtemp(prefix=f"flm-bench-asr-{model['id']}-"))
    output_stem = output_dir / "transcript"
    result = run_command(asr_command(model, reference_audio, output_stem), timeout_seconds, cwd=output_dir)
    transcript_path = output_stem.with_suffix(".txt")
    if transcript_path.exists():
        result.output = transcript_path.read_text().strip()
        reference_seconds = audio_duration_seconds(reference_audio)
        if reference_seconds is not None and result.duration_seconds > 0:
            realtime_factor = result.duration_seconds / reference_seconds
            result.speed_label = f"RTF {realtime_factor:.2f}"
            result.metrics = {
                "audio_duration_seconds": round(reference_seconds, 3),
                "realtime_factor": round(realtime_factor, 3),
            }
    elif result.status == "passed":
        result.status = "failed"
        result.error = "process exited successfully but produced no transcript"
    return task_record(model, "speech_to_text", [result])


def benchmark_image(model: dict[str, Any], timeout_seconds: int, steps_cap: int) -> dict[str, Any]:
    output_dir = Path(tempfile.mkdtemp(prefix=f"flm-bench-image-{model['id']}-"))
    output_path = output_dir / "image.png"
    result = run_command(image_command(model, output_path, steps_cap), timeout_seconds, cwd=output_dir)
    if output_path.exists():
        result.artifact_path = str(output_path)
        result.artifact_bytes = output_path.stat().st_size
        result.output = f"{output_path.name} ({format_bytes(result.artifact_bytes)})"
        if result.duration_seconds > 0:
            result.speed_label = f"{result.duration_seconds:.1f}s/image"
            result.metrics = {"seconds_per_image": round(result.duration_seconds, 3)}
    elif result.status == "passed":
        result.status = "failed"
        result.error = "process exited successfully but produced no image"
    return task_record(model, "image_generation", [result])


def task_record(
    model: dict[str, Any],
    task: str,
    runs: list[RunResult],
    status: str | None = None,
    error: str | None = None,
) -> dict[str, Any]:
    if status is None:
        if not runs:
            status = "skipped"
        elif any(run.status == "passed" for run in runs) and all(run.status == "passed" for run in runs):
            status = "passed"
        elif any(run.status == "timeout" for run in runs):
            status = "timeout"
        else:
            status = "failed"
    return {
        "model_id": model["id"],
        "model_name": model["display_name"],
        "runtime": model["runtime"],
        "task": task,
        "status": status,
        "size_bytes": model["size_bytes"],
        "error": error,
        "runs": [
            {
                "status": run.status,
                "duration_seconds": round(run.duration_seconds, 3),
                "output": run.output,
                "artifact_path": run.artifact_path,
                "artifact_bytes": run.artifact_bytes,
                "error": run.error,
                "speed": run.speed_label,
                "metrics": run.metrics or {},
                "stdout_tail": tail(run.stdout),
                "stderr_tail": tail(run.stderr),
                "command": redact_paths(run.command),
            }
            for run in runs
        ],
    }


def redact_paths(command: list[str]) -> list[str]:
    home = str(Path.home())
    return [part.replace(home, "~") for part in command]


def create_reference_audio(models: list[dict[str, Any]], timeout_seconds: int) -> tuple[Path | None, str]:
    reference_text = "Hello, this is a reusable reference voice sample for local model tests."
    kokoro = next((model for model in models if model["id"] == "kokoro-82m-4bit"), None)
    if kokoro is None:
        return None, reference_text
    output_dir = Path(tempfile.mkdtemp(prefix="flm-bench-reference-audio-"))
    result = run_command(
        tts_command(kokoro, reference_text, output_dir, reference_audio=None, reference_text=reference_text),
        timeout_seconds,
        cwd=output_dir,
    )
    if result.status != "passed":
        return None, reference_text
    return find_audio_file(output_dir, "wav"), reference_text


def system_info() -> dict[str, Any]:
    def shell(command: list[str]) -> str:
        try:
            return subprocess.check_output(command, text=True).strip()
        except Exception:
            return ""

    memsize = shell(["sysctl", "-n", "hw.memsize"])
    return {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "macos": shell(["sw_vers", "-productVersion"]),
        "cpu": shell(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "memory_bytes": int(memsize) if memsize.isdigit() else None,
        "python": sys.version.split()[0],
        "mlx_python": mlx_python(),
    }


def write_markdown(report: dict[str, Any], path: Path) -> None:
    lines = [
        "# Local Model Benchmark Report",
        "",
        f"Generated: `{report['system']['timestamp_utc']}`",
        "",
        "## Environment",
        "",
        f"- macOS: `{report['system']['macos'] or 'unknown'}`",
        f"- CPU: `{report['system']['cpu'] or 'unknown'}`",
        f"- Memory: `{format_bytes(report['system']['memory_bytes'])}`",
        f"- MLX Python: `{report['system']['mlx_python']}`",
        "",
        "## Method",
        "",
        "- Chat: two short prompts, measured as cold request + immediate second request.",
        "- TTS: two short synthesis requests, checks that an audio artifact is actually created.",
        "- ASR: one transcription request using a generated Kokoro reference clip.",
        f"- Image: one 512×512 smoke prompt with steps capped at {report['image_steps_cap']} to avoid multi-hour runs.",
        "- Speed: chat uses output characters/sec; audio uses real-time factor (`RTF`, lower is better); image uses seconds/image.",
        "- The current app uses process-per-request runners; the second run mainly benefits from OS/page cache, not a persistent resident model.",
        "",
        "## Summary",
        "",
        "| Model | Task | Size | Status | Cold / Run 1 | Second / Run 2 | Speed | Output |",
        "|---|---:|---:|---|---:|---:|---:|---|",
    ]
    for result in report["results"]:
        runs = result["runs"]
        first = runs[0] if runs else None
        second = runs[1] if len(runs) > 1 else None
        output = ""
        chosen_run = second or first
        if second and second.get("output"):
            output = second["output"]
        elif first and first.get("output"):
            output = first["output"]
        elif result.get("error"):
            output = result["error"]
        elif first and first.get("error"):
            output = first["error"]
        if chosen_run and chosen_run.get("status") != "passed":
            output = run_diagnostic(chosen_run)
        speed = ""
        if second and second.get("status") == "passed" and second.get("speed"):
            speed = second["speed"]
        elif first and first.get("status") == "passed" and first.get("speed"):
            speed = first["speed"]
        output = compact_cell(output)
        lines.append(
            "| {model} | {task} | {size} | {status} | {first_time} | {second_time} | {speed} | {output} |".format(
                model=result["model_name"],
                task=result["task"],
                size=format_bytes(result["size_bytes"]),
                status=result["status"],
                first_time=format_seconds(first["duration_seconds"]) if first else "—",
                second_time=format_seconds(second["duration_seconds"]) if second else "—",
                speed=compact_cell(speed),
                output=output,
            )
        )
    lines += benchmark_highlights(report)
    lines += [
        "",
        "## Failures / Skips",
        "",
    ]
    failures = [
        result
        for result in report["results"]
        if result["status"] not in {"passed"}
    ]
    if not failures:
        lines.append("- None.")
    else:
        for result in failures:
            details = result.get("error") or ""
            if not details and result["runs"]:
                details = run_diagnostic(result["runs"][-1])
            elif result["runs"]:
                diagnostic = run_diagnostic(result["runs"][-1])
                if diagnostic and diagnostic != details:
                    details = f"{details}; {diagnostic}"
            lines.append(f"- **{result['model_name']} / {result['task']}**: `{result['status']}` — {compact_cell(details, 280)}")
    lines += [
        "",
        "## Raw Artifacts",
        "",
        f"- JSON: `{report['json_path']}`",
    ]
    path.write_text("\n".join(lines).rstrip() + "\n")


def benchmark_highlights(report: dict[str, Any]) -> list[str]:
    total = len(report["results"])
    passed = sum(1 for result in report["results"] if result["status"] == "passed")
    lines = [
        "",
        "## Highlights",
        "",
        f"- Passed: `{passed}/{total}` benchmark tasks.",
    ]
    for highlight in [
        best_result(
            report,
            task="chat",
            metric="chars_per_second",
            maximize=True,
            label=lambda result, run, value: (
                f"Fastest chat throughput: `{result['model_name']}` at `{value:.1f} chars/s`."
            ),
        ),
        best_result(
            report,
            task="text_to_speech",
            metric="realtime_factor",
            maximize=False,
            label=lambda result, run, value: (
                f"Best TTS RTF: `{result['model_name']}` at `RTF {value:.2f}` "
                f"(`{format_seconds(run['duration_seconds'])}` wall time)."
            ),
        ),
        best_result(
            report,
            task="speech_to_text",
            metric="realtime_factor",
            maximize=False,
            label=lambda result, run, value: (
                f"ASR smoke test: `{result['model_name']}` at `RTF {value:.2f}`."
            ),
        ),
        best_result(
            report,
            task="image_generation",
            metric="seconds_per_image",
            maximize=False,
            label=lambda result, run, value: (
                f"Fastest image smoke test: `{result['model_name']}` at `{value:.1f}s/image`."
            ),
        ),
    ]:
        if highlight:
            lines.append(f"- {highlight}")
    return lines


def best_result(
    report: dict[str, Any],
    *,
    task: str,
    metric: str,
    maximize: bool,
    label,
) -> str | None:
    candidates: list[tuple[float, dict[str, Any], dict[str, Any]]] = []
    for result in report["results"]:
        if result["status"] != "passed" or result["task"] != task:
            continue
        for run in result["runs"]:
            value = run.get("metrics", {}).get(metric)
            if isinstance(value, (int, float)):
                candidates.append((float(value), result, run))
    if not candidates:
        return None
    value, result, run = sorted(candidates, key=lambda item: item[0], reverse=maximize)[0]
    return label(result, run, value)


def run_diagnostic(run: dict[str, Any]) -> str:
    error = (run.get("error") or "").strip()
    stderr = (run.get("stderr_tail") or "").strip()
    stdout = (run.get("stdout_tail") or "").strip()
    if error.startswith("exit code") and (stderr or stdout):
        return f"{error}; {last_relevant_line(stderr or stdout)}"
    return next((part for part in [error, stderr, stdout] if part), "—")


def last_relevant_line(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else text.strip()


def compact_cell(value: str | None, limit: int = 180) -> str:
    if not value:
        return "—"
    clean = re.sub(r"\s+", " ", value).strip().replace("|", "\\|")
    if len(clean) <= limit:
        return clean
    return clean[: limit - 1] + "…"


def format_seconds(value: float) -> str:
    if value < 1:
        return f"{value * 1000:.0f} ms"
    if value < 60:
        return f"{value:.1f}s"
    minutes = int(value // 60)
    seconds = int(value % 60)
    return f"{minutes}m {seconds}s"


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark installed Flutter Local Models Studio models.")
    parser.add_argument("--models-dir", type=Path, default=default_models_dir())
    parser.add_argument("--output-dir", type=Path, default=Path("benchmarks"))
    parser.add_argument("--chat-timeout", type=int, default=420)
    parser.add_argument("--tts-timeout", type=int, default=420)
    parser.add_argument("--asr-timeout", type=int, default=300)
    parser.add_argument("--image-timeout", type=int, default=360)
    parser.add_argument("--image-steps-cap", type=int, default=4)
    parser.add_argument("--chat-max-tokens", type=int, default=64)
    parser.add_argument("--skip-image", action="store_true")
    args = parser.parse_args()

    models = load_installed_models(args.models_dir)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    reference_audio, reference_text = create_reference_audio(models, args.tts_timeout)

    results: list[dict[str, Any]] = []
    for model in models:
        if model_supports_chat(model):
            print(f"chat: {model['display_name']}", flush=True)
            results.append(benchmark_chat(model, args.chat_timeout, args.chat_max_tokens))
        if model_supports_tts(model):
            print(f"tts: {model['display_name']}", flush=True)
            results.append(benchmark_tts(model, args.tts_timeout, reference_audio, reference_text))
        if model_supports_asr(model):
            print(f"asr: {model['display_name']}", flush=True)
            results.append(benchmark_asr(model, args.asr_timeout, reference_audio))
        if model_supports_image(model):
            if args.skip_image:
                results.append(task_record(model, "image_generation", [], status="skipped", error="image benchmarks disabled"))
            else:
                print(f"image: {model['display_name']}", flush=True)
                results.append(benchmark_image(model, args.image_timeout, args.image_steps_cap))

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    json_path = args.output_dir / f"local-model-benchmark-{timestamp}.json"
    markdown_path = args.output_dir / "README.md"
    report = {
        "system": system_info(),
        "models_dir": str(args.models_dir),
        "reference_audio": str(reference_audio) if reference_audio else None,
        "image_steps_cap": args.image_steps_cap,
        "results": results,
        "json_path": str(json_path),
    }
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    write_markdown(report, markdown_path)
    print(markdown_path)
    print(json_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
