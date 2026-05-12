#!/usr/bin/env python3
"""Re-upload small metadata files to an existing GitHub release without rebuilding weights."""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import tempfile


from bundle_model import build_model_metadata, build_release_notes, load_manifest


def gh(args: list[str]) -> None:
    subprocess.run(["gh", *args], check=True, text=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Publish registry YAML + JSON metadata to an existing release (archive parts unchanged).",
    )
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument(
        "--release-tag",
        required=False,
        help="GitHub release tag (default: packaging.release_tag from the manifest)",
    )
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    tag = (args.release_tag or manifest.release_tag).strip()
    if not tag:
        raise SystemExit("Empty release tag")

    with tempfile.TemporaryDirectory() as tmp:
        tdir = pathlib.Path(tmp)
        gh(
            [
                "release",
                "download",
                tag,
                "--pattern",
                "release_metadata.json",
                "--dir",
                str(tdir),
            ],
        )
        old_path = tdir / "release_metadata.json"
        if not old_path.is_file():
            raise SystemExit(f"Downloaded release {tag!r} is missing release_metadata.json")

        old = json.loads(old_path.read_text())
        if old.get("id") != manifest.id:
            raise SystemExit(f"release id mismatch: JSON has {old.get('id')!r}, manifest has {manifest.id!r}")
        if old.get("release_tag") != manifest.release_tag:
            raise SystemExit(
                "release_tag mismatch: existing JSON has "
                f"{old.get('release_tag')!r}, manifest packaging has {manifest.release_tag!r}",
            )

        model_meta = build_model_metadata(manifest, old)
        new_release = dict(old)
        new_release["runtime_config"] = manifest.runtime_config

        out_dir = tdir / "out"
        out_dir.mkdir()
        (out_dir / "release_metadata.json").write_text(
            json.dumps(new_release, indent=2, ensure_ascii=False) + "\n",
        )
        (out_dir / "model_metadata.json").write_text(
            json.dumps(model_meta, indent=2, ensure_ascii=False) + "\n",
        )
        (out_dir / "manifest.source.yaml").write_text(args.manifest.read_text())
        (out_dir / "release_notes.md").write_text(build_release_notes(model_meta))

        gh(
            [
                "release",
                "upload",
                tag,
                str(out_dir / "release_metadata.json"),
                str(out_dir / "model_metadata.json"),
                str(out_dir / "manifest.source.yaml"),
                "--clobber",
            ],
        )
        gh(["release", "edit", tag, "--notes-file", str(out_dir / "release_notes.md")])

    print(f"Updated metadata for release {tag!r} (archive chunks untouched).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
