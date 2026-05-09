import pathlib
import tempfile
import unittest

import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "model_release"))

import bundle_model  # noqa: E402


class BundleModelTests(unittest.TestCase):
    def test_load_manifest(self) -> None:
        manifest_path = ROOT / "registry" / "models" / "qwen3-asr-0.6b-4bit.yaml"
        manifest = bundle_model.load_manifest(manifest_path)
        self.assertEqual(manifest.id, "qwen3-asr-0.6b-4bit")
        self.assertEqual(manifest.release_tag, "model-qwen3-asr-0.6b-4bit")

    def test_split_file_creates_numbered_parts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            source = tmp_path / "archive.tar"
            source.write_bytes(b"a" * 10)

            parts = bundle_model.split_file(
                input_path=source,
                output_dir=tmp_path,
                chunk_size_bytes=4,
                asset_prefix="sample-model",
            )

            self.assertEqual(len(parts), 3)
            self.assertEqual(parts[0]["file_name"], "sample-model.part-000")
            self.assertEqual(parts[2]["size_bytes"], 2)


if __name__ == "__main__":
    unittest.main()
