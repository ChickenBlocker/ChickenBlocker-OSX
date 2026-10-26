#!/usr/bin/env python3
"""Build and publish a signed ChickenBlocker release."""

import argparse
import gzip
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = 1
ACTION = "install-release-v1"
MAX_BUNDLE_BYTES = 100 * 1024 * 1024
MAX_FILES = 1000


class PublishError(Exception):
    pass


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_file(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            size += len(chunk)
            digest.update(chunk)
    return digest.hexdigest(), size


def validate_private_key(path):
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError as error:
        raise PublishError(f"private key not found: {path}") from error
    if mode & 0o077:
        raise PublishError(f"private key must not be group/world accessible: {path}")


def bundle_entries(bundle_dir):
    installer = bundle_dir / "install.sh"
    if not installer.is_file() or installer.is_symlink():
        raise PublishError("bundle must contain a regular top-level install.sh")
    if not os.access(installer, os.X_OK):
        raise PublishError("bundle install.sh must be executable")

    entries = []
    total = 0
    for path in sorted(bundle_dir.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(bundle_dir)
        if path.is_symlink():
            raise PublishError(f"bundle links are forbidden: {relative}")
        if not path.is_dir() and not path.is_file():
            raise PublishError(f"unsupported bundle entry: {relative}")
        if path.is_file():
            total += path.stat().st_size
            if total > MAX_BUNDLE_BYTES:
                raise PublishError("bundle exceeds uncompressed size limit")
        entries.append((path, relative))
    if len(entries) > MAX_FILES:
        raise PublishError("bundle contains too many entries")
    return entries


def build_archive(bundle_dir, output):
    entries = bundle_entries(bundle_dir)
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path, relative in entries:
                    info = archive.gettarinfo(str(path), arcname=relative.as_posix())
                    info.uid = 0
                    info.gid = 0
                    info.uname = "root"
                    info.gname = "wheel"
                    info.mtime = 0
                    info.pax_headers = {}
                    if info.isfile():
                        with path.open("rb") as handle:
                            archive.addfile(info, handle)
                    else:
                        archive.addfile(info)


def read_current_sequence(release_dir):
    current = release_dir / "current.json"
    if not current.exists():
        return 0
    try:
        value = json.loads(current.read_text())
        return int(value["sequence"])
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise PublishError(f"cannot read current sequence from {current}") from error


def atomic_copy(source, destination, mode=0o644):
    temporary = destination.with_name(destination.name + ".new")
    with source.open("rb") as source_handle, temporary.open("wb") as target_handle:
        shutil.copyfileobj(source_handle, target_handle)
        target_handle.flush()
        os.fsync(target_handle.fileno())
    temporary.chmod(mode)
    os.replace(temporary, destination)


def publish(bundle_dir, release_dir, private_key, sequence, openssl="/usr/bin/openssl"):
    validate_private_key(private_key)
    if sequence <= 0:
        raise PublishError("sequence must be a positive integer")
    release_dir.mkdir(parents=True, exist_ok=True)
    payload_dir = release_dir / "payloads"
    manifest_dir = release_dir / "manifests"
    payload_dir.mkdir(mode=0o755, exist_ok=True)
    manifest_dir.mkdir(mode=0o755, exist_ok=True)
    current_sequence = read_current_sequence(release_dir)
    if sequence <= current_sequence:
        raise PublishError(f"sequence must exceed current sequence {current_sequence}")

    payload_name = f"release-{sequence:08d}.tar.gz"
    payload_relative = f"payloads/{payload_name}"
    payload_path = payload_dir / payload_name
    if payload_path.exists():
        raise PublishError(f"payload already exists: {payload_path}")
    historical_manifest = manifest_dir / f"release-{sequence:08d}.json"
    historical_signature = manifest_dir / f"release-{sequence:08d}.sig"
    if historical_manifest.exists() or historical_signature.exists():
        raise PublishError(f"manifest history already exists for sequence {sequence}")

    with tempfile.TemporaryDirectory(dir=release_dir) as temporary_name:
        temporary = Path(temporary_name)
        archive = temporary / payload_name
        build_archive(bundle_dir, archive)
        digest, size = sha256_file(archive)
        manifest = {
            "action": ACTION,
            "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
            "payload": payload_relative,
            "sequence": sequence,
            "sha256": digest,
            "size": size,
            "version": SCHEMA_VERSION,
        }
        manifest_path = temporary / "current.json"
        signature_path = temporary / "current.sig"
        manifest_path.write_bytes(canonical_json(manifest))
        try:
            subprocess.run(
                [openssl, "dgst", "-sha256", "-sign", str(private_key),
                 "-out", str(signature_path), str(manifest_path)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            detail = getattr(error, "stderr", b"").decode(errors="replace").strip()
            raise PublishError(f"OpenSSL signing failed: {detail or error}") from error

        atomic_copy(archive, payload_path)
        atomic_copy(manifest_path, historical_manifest)
        atomic_copy(signature_path, historical_signature)
        # Publish the signature first. A reader racing this update sees either
        # the old release or a temporary signature mismatch and retries later.
        atomic_copy(signature_path, release_dir / "current.sig")
        atomic_copy(manifest_path, release_dir / "current.json")
    return manifest


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--release-dir", default=Path("/var/lib/chickenblocker-release/public"), type=Path)
    parser.add_argument("--private-key", default=Path("/etc/chickenblocker-release/signing-key.pem"), type=Path)
    parser.add_argument("--sequence", required=True, type=int)
    parser.add_argument("--openssl", default="/usr/bin/openssl")
    return parser.parse_args()


def main():
    args = parse_args()
    try:
        manifest = publish(
            args.bundle.resolve(), args.release_dir.resolve(),
            args.private_key.resolve(), args.sequence, args.openssl,
        )
    except PublishError as error:
        raise SystemExit(f"ERROR: {error}")
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
