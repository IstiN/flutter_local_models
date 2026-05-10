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
        self.assertEqual(manifest.model_card["languages"][0], "ru")

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

    def test_model_metadata_contains_runtime_and_card(self) -> None:
        manifest_path = ROOT / "registry" / "models" / "dia-1.6b-4bit.yaml"
        manifest = bundle_model.load_manifest(manifest_path)
        release_metadata = {
            "resolved_revision": "main",
            "archive_size_bytes": 123,
            "archive_sha256": "abc",
            "parts": [{"file_name": "dia.part-000", "size_bytes": 123}],
        }

        metadata = bundle_model.build_model_metadata(manifest, release_metadata)
        notes = bundle_model.build_release_notes(metadata)

        self.assertEqual(metadata["schema_version"], 1)
        self.assertEqual(metadata["model_card"]["summary"], manifest.description)
        self.assertEqual(metadata["runtime_config"]["output"]["media_type"], "audio/wav")
        self.assertIn("Default parameters", notes)

    def test_release_metadata_contains_runtime_config(self) -> None:
        manifest_path = ROOT / "registry" / "models" / "qwen3-tts-12hz-1.7b-base-4bit.yaml"
        manifest = bundle_model.load_manifest(manifest_path)
        with tempfile.TemporaryDirectory() as tmp:
            archive = pathlib.Path(tmp) / "model.tar"
            archive.write_bytes(b"model")
            release_metadata = bundle_model.build_release_metadata(
                manifest,
                archive,
                [{"file_name": "model.part-000", "size_bytes": 5}],
                "main",
            )

        self.assertEqual(
            release_metadata["runtime_config"]["default_parameters"]["voice"],
            "Ethan",
        )
        self.assertEqual(
            release_metadata["runtime_config"]["default_parameters"]["lang_code"],
            "ru",
        )


if __name__ == "__main__":
    unittest.main()
