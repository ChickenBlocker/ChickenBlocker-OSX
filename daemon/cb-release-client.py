#!/usr/bin/env python3
"""Fetch, verify, and apply one signed ChickenBlocker release."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath


SCHEMA_KEYS = {"action", "created_at", "payload", "sequence", "sha256", "size", "version"}
CONFIG_KEYS = {"audit", "base_url"}
PAYLOAD_RE = re.compile(r"payloads/release-([0-9]{8})\.tar\.gz\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
MAX_MANIFEST_BYTES = 32 * 1024
MAX_SIGNATURE_BYTES = 16 * 1024
MAX_PAYLOAD_BYTES = 100 * 1024 * 1024
MAX_EXTRACTED_BYTES = 100 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 1000
MAX_INSTALL_OUTPUT = 16 * 1024
INITIAL_BACKOFF = 60
MAX_BACKOFF = 15 * 60


class ReleaseError(Exception):
    pass


def canonical_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def bounded_read(response, limit):
    declared = response.headers.get("Content-Length")
    if declared:
        try:
            if int(declared) > limit:
                raise ReleaseError("download exceeds size limit")
        except ValueError as error:
            raise ReleaseError("invalid Content-Length") from error
    data = response.read(limit + 1)
    if len(data) > limit:
        raise ReleaseError("download exceeds size limit")
    return data


def fetch(url, limit, timeout=10):
    request = urllib.request.Request(url, headers={"User-Agent": "ChickenBlocker-Release/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                raise ReleaseError(f"HTTP status {response.status}")
            return bounded_read(response, limit)
    except (OSError, urllib.error.URLError) as error:
        raise ReleaseError(f"download failed: {error}") from error


def validate_manifest(raw):
    try:
        manifest = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError("manifest is not valid JSON") from error
    if not isinstance(manifest, dict) or set(manifest) != SCHEMA_KEYS:
        raise ReleaseError("manifest schema is invalid")
    if canonical_json(manifest) != raw:
        raise ReleaseError("manifest is not canonical JSON")
    if manifest["version"] != 1 or manifest["action"] != "install-release-v1":
        raise ReleaseError("manifest version or action is unsupported")
    sequence = manifest["sequence"]
    size = manifest["size"]
    if type(sequence) is not int or sequence <= 0:
        raise ReleaseError("manifest sequence is invalid")
    if type(size) is not int or size <= 0 or size > MAX_PAYLOAD_BYTES:
        raise ReleaseError("manifest payload size is invalid")
    match = PAYLOAD_RE.fullmatch(manifest["payload"]) if isinstance(manifest["payload"], str) else None
    if not match or int(match.group(1)) != sequence:
        raise ReleaseError("manifest payload path is invalid")
    if not isinstance(manifest["sha256"], str) or not SHA256_RE.fullmatch(manifest["sha256"]):
        raise ReleaseError("manifest SHA-256 is invalid")
    if not isinstance(manifest["created_at"], str) or len(manifest["created_at"]) > 64:
        raise ReleaseError("manifest creation time is invalid")
    return manifest


def verify_signature(manifest_path, signature_path, public_key, openssl):
    try:
        key_info = subprocess.run(
            [openssl, "pkey", "-pubin", "-in", str(public_key), "-text", "-noout"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        match = re.search(rb"(?:Public-Key|RSA Public-Key): \(([0-9]+) bit\)", key_info.stdout)
        if key_info.returncode != 0 or not match:
            raise ReleaseError("cannot determine RSA public-key size")
        key_bits = int(match.group(1))
        if key_bits < 2048 or signature_path.stat().st_size != (key_bits + 7) // 8:
            raise ReleaseError("manifest signature length is invalid")
        result = subprocess.run(
            [openssl, "dgst", "-sha256", "-verify", str(public_key),
             "-signature", str(signature_path), str(manifest_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise ReleaseError(f"cannot execute OpenSSL: {error}") from error
    if result.returncode != 0:
        raise ReleaseError("manifest signature verification failed")


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def validate_archive_member(member):
    path = PurePosixPath(member.name)
    if not member.name or path.is_absolute() or ".." in path.parts:
        raise ReleaseError(f"unsafe archive path: {member.name!r}")
    if not member.isdir() and not member.isfile():
        raise ReleaseError(f"unsupported archive entry: {member.name}")


def safe_extract(archive_path, destination):
    total = 0
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            members = archive.getmembers()
            if len(members) > MAX_ARCHIVE_ENTRIES:
                raise ReleaseError("archive contains too many entries")
            names = set()
            for member in members:
                validate_archive_member(member)
                if member.name in names:
                    raise ReleaseError(f"duplicate archive entry: {member.name}")
                names.add(member.name)
                if member.isfile():
                    total += member.size
                    if total > MAX_EXTRACTED_BYTES:
                        raise ReleaseError("archive exceeds extracted size limit")
            for member in members:
                target = destination.joinpath(*PurePosixPath(member.name).parts)
                if member.isdir():
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise ReleaseError(f"cannot read archive entry: {member.name}")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                target.chmod(member.mode & 0o755)
    except (OSError, tarfile.TarError) as error:
        raise ReleaseError(f"cannot extract release archive: {error}") from error
    installer = destination / "install.sh"
    if not installer.is_file() or installer.is_symlink():
        raise ReleaseError("release has no regular top-level install.sh")
    return installer


def default_state():
    return {"failures": 0, "last_sequence": 0, "next_attempt": 0}


def load_state(path):
    if not path.exists():
        return default_state()
    try:
        state = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError("release state is unreadable; refusing rollback") from error
    if set(state) != {"failures", "last_sequence", "next_attempt"}:
        raise ReleaseError("release state schema is invalid; refusing rollback")
    if any(type(state[key]) is not int or state[key] < 0 for key in state):
        raise ReleaseError("release state values are invalid; refusing rollback")
    return state


def store_state(path, state):
    temporary = path.with_name(path.name + ".new")
    with temporary.open("w") as handle:
        json.dump(state, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.chmod(0o600)
    os.replace(temporary, path)


def record_failure(state_path, state, now):
    failures = min(state["failures"] + 1, 20)
    delay = min(INITIAL_BACKOFF * (2 ** (failures - 1)), MAX_BACKOFF)
    state.update(failures=failures, next_attempt=now + delay)
    store_state(state_path, state)


def load_config(path):
    try:
        config = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"cannot read configuration: {path}") from error
    if not isinstance(config, dict) or set(config) != CONFIG_KEYS:
        raise ReleaseError("configuration schema is invalid")
    base_url = config["base_url"]
    if not isinstance(base_url, str) or not re.fullmatch(r"https?://[A-Za-z0-9.:-]+", base_url):
        raise ReleaseError("configuration base_url is invalid")
    if type(config["audit"]) is not bool:
        raise ReleaseError("configuration audit must be boolean")
    return config


class ReleaseClient:
    def __init__(self, config_path, public_key, state_dir,
                 openssl="/usr/bin/openssl", logger=None, now=None):
        self.config = load_config(config_path)
        self.public_key = public_key
        self.state_dir = state_dir
        self.openssl = openssl
        self.logger = logger or (lambda message: None)
        self.now = now or (lambda: int(time.time()))

    def run(self):
        self.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_path = self.state_dir / "client.lock"
        with lock_path.open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return "already-running"
            return self._run_locked()

    def _run_locked(self):
        state_path = self.state_dir / "state.json"
        state = load_state(state_path)
        now = self.now()
        if now < state["next_attempt"]:
            return "backoff"
        try:
            result = self._check_release(state)
        except ReleaseError as error:
            record_failure(state_path, state, now)
            self.logger(f"release rejected: {error}")
            return "rejected"
        state.update(failures=0, next_attempt=0)
        store_state(state_path, state)
        return result

    def _check_release(self, state):
        base = self.config["base_url"]
        manifest_raw = fetch(base + "/current.json", MAX_MANIFEST_BYTES)
        signature_raw = fetch(base + "/current.sig", MAX_SIGNATURE_BYTES)
        with tempfile.TemporaryDirectory(dir=self.state_dir) as temporary_name:
            temporary = Path(temporary_name)
            manifest_path = temporary / "manifest.json"
            signature_path = temporary / "manifest.sig"
            manifest_path.write_bytes(manifest_raw)
            signature_path.write_bytes(signature_raw)
            verify_signature(manifest_path, signature_path, self.public_key, self.openssl)
            manifest = validate_manifest(manifest_raw)
            sequence = manifest["sequence"]
            if sequence < state["last_sequence"]:
                raise ReleaseError("release sequence is a rollback")
            if sequence == state["last_sequence"]:
                return "up-to-date"
            payload = fetch(base + "/" + manifest["payload"], manifest["size"])
            if len(payload) != manifest["size"] or sha256_bytes(payload) != manifest["sha256"]:
                raise ReleaseError("payload size or SHA-256 mismatch")
            archive_path = temporary / "release.tar.gz"
            archive_path.write_bytes(payload)
            extracted = temporary / "extracted"
            extracted.mkdir(mode=0o700)
            installer = safe_extract(archive_path, extracted)
            environment = os.environ.copy()
            environment["CB_RELEASE_SEQUENCE"] = str(sequence)
            try:
                completed = subprocess.run(
                    ["/bin/bash", str(installer)], cwd=extracted, env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    timeout=300,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                raise ReleaseError(f"release installer failed: {error}") from error
            output = completed.stdout[-MAX_INSTALL_OUTPUT:].decode(errors="replace").strip()
            if completed.returncode != 0:
                raise ReleaseError(f"release installer exited {completed.returncode}: {output}")
            if self.config["audit"]:
                self._audit()
            state["last_sequence"] = sequence
            self.logger(f"applied release {sequence}: {output or 'no installer output'}")
            return "applied"

    @staticmethod
    def _audit():
        base = Path("/Library/Application Support/ChickenBlocker")
        command = [str(base / "bin/cb-bash"), str(base / "verifier.sh"), "check"]
        try:
            completed = subprocess.run(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReleaseError(f"post-install audit failed: {error}") from error
        if completed.returncode != 0:
            output = completed.stdout[-MAX_INSTALL_OUTPUT:].decode(errors="replace").strip()
            raise ReleaseError(f"post-install audit failed: {output}")


def bounded_logger(path):
    def write(message):
        try:
            if path.exists() and path.stat().st_size > 128 * 1024:
                lines = path.read_text(errors="replace").splitlines()[-400:]
                path.write_text("\n".join(lines) + "\n")
            with path.open("a") as handle:
                stamp = time.strftime("%Y-%m-%d %H:%M:%S")
                handle.write(f"{stamp} {message}\n")
        except OSError:
            pass
    return write


def parse_args():
    base = Path("/Library/Application Support/ChickenBlocker/release")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=base / "config.json")
    parser.add_argument("--public-key", type=Path, default=base / "signing-public.pem")
    parser.add_argument("--state-dir", type=Path, default=base / "state")
    parser.add_argument("--openssl", default="/usr/bin/openssl")
    return parser.parse_args()


def main():
    args = parse_args()
    log_path = args.state_dir.parent / "release.log"
    logger = bounded_logger(log_path)
    try:
        result = ReleaseClient(
            args.config, args.public_key, args.state_dir, args.openssl, logger,
        ).run()
    except ReleaseError as error:
        logger(f"fatal release client error: {error}")
        raise SystemExit(1)
    logger(f"release check: {result}")


if __name__ == "__main__":
    main()
