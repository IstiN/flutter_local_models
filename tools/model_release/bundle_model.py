#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import pathlib
import tarfile
from typing import Any

import yaml
from huggingface_hub import snapshot_download


class BundleError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Manifest:
    id: str
    repo: str
    revision: str
    release_tag: str
    archive_name: str
    chunk_size_bytes: int
    asset_prefix: str


def load_manifest(path: pathlib.Path) -> Manifest:
    data = yaml.safe_load(path.read_text())
    return Manifest(
        id=data["id"],
        repo=data["source"]["repo"],
        revision=data["source"].get("revision", "main"),
        release_tag=data["packaging"]["release_tag"],
        archive_name=data["packaging"]["archive_name"],
        chunk_size_bytes=int(data["packaging"]["chunk_size_bytes"]),
        asset_prefix=data["packaging"]["asset_prefix"],
    )


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def create_tar_archive(source_dir: pathlib.Path, archive_path: pathlib.Path, root_name: str) -> pathlib.Path:
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, "w") as archive:
        archive.add(source_dir, arcname=root_name)
    return archive_path


def split_file(
    input_path: pathlib.Path,
    output_dir: pathlib.Path,
    chunk_size_bytes: int,
    asset_prefix: str,
) -> list[dict[str, Any]]:
    output_dir.mkdir(parents=True, exist_ok=True)
    parts: list[dict[str, Any]] = []
    with input_path.open("rb") as source:
        index = 0
        while True:
            chunk = source.read(chunk_size_bytes)
            if not chunk:
                break
            part_name = f"{asset_prefix}.part-{index:03d}"
            part_path = output_dir / part_name
            part_path.write_bytes(chunk)
            parts.append(
                {
                    "index": index,
                    "file_name": part_name,
                    "size_bytes": len(chunk),
                    "sha256": sha256_file(part_path),
                }
            )
            index += 1
    return parts


def build_release_metadata(
    manifest: Manifest,
    archive_path: pathlib.Path,
    parts: list[dict[str, Any]],
    resolved_revision: str,
) -> dict[str, Any]:
    return {
        "id": manifest.id,
        "repo": manifest.repo,
        "release_tag": manifest.release_tag,
        "resolved_revision": resolved_revision,
        "archive_name": archive_path.name,
        "archive_sha256": sha256_file(archive_path),
        "archive_size_bytes": archive_path.stat().st_size,
        "chunk_size_bytes": manifest.chunk_size_bytes,
        "parts": parts,
    }


def download_snapshot(manifest: Manifest, target_dir: pathlib.Path, revision_override: str | None) -> tuple[pathlib.Path, str]:
    revision = revision_override or manifest.revision
    snapshot_path = snapshot_download(
        repo_id=manifest.repo,
        revision=revision,
        local_dir=target_dir,
    )
    return pathlib.Path(snapshot_path), revision


def build_release_bundle(manifest_path: pathlib.Path, output_dir: pathlib.Path, revision_override: str | None) -> pathlib.Path:
    manifest = load_manifest(manifest_path)
    staging_dir = output_dir / "staging" / manifest.id
    bundle_dir = output_dir / "bundle" / manifest.id
    bundle_dir.mkdir(parents=True, exist_ok=True)

    snapshot_path, resolved_revision = download_snapshot(manifest, staging_dir, revision_override)
    archive_path = create_tar_archive(snapshot_path, bundle_dir / manifest.archive_name, manifest.id)
    parts = split_file(archive_path, bundle_dir, manifest.chunk_size_bytes, manifest.asset_prefix)
    metadata = build_release_metadata(manifest, archive_path, parts, resolved_revision)

    metadata_path = bundle_dir / "release_metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2))
    (bundle_dir / "manifest.source.yaml").write_text(manifest_path.read_text())
    archive_path.unlink()
    return metadata_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a GitHub Release bundle from a model manifest.")
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--revision", required=False)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    metadata_path = build_release_bundle(args.manifest, args.output_dir, args.revision)
    print(metadata_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
