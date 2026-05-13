#!/usr/bin/env python3
"""Запускает `qwen3_tts_triple_demo_cli.py --self-test` из корня репозитория."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


class TestQwen3TtsTripleDemoCli(unittest.TestCase):
    def test_demo_emits_three_wavs(self) -> None:
        script = Path(__file__).resolve().parent / "qwen3_tts_triple_demo_cli.py"
        proc = subprocess.run(
            [sys.executable, str(script), "--self-test"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        self.assertIn("self-test OK", proc.stdout)


if __name__ == "__main__":
    unittest.main()
