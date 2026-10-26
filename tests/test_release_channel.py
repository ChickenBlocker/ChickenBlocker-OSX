import functools
import http.server
import importlib.util
import io
import json
import os
import subprocess
import tarfile
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PUBLISHER = load_module("publish_release", ROOT / "tools" / "publish-release.py")
CLIENT = load_module("release_client", ROOT / "daemon" / "cb-release-client.py")


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass


class ReleaseServer:
    def __init__(self, directory):
        handler = functools.partial(QuietHandler, directory=str(directory))
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        host, port = self.server.server_address
        return f"http://{host}:{port}"

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class ReleaseChannelTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.private_key = self.root / "private.pem"
        self.public_key = self.root / "public.pem"
        subprocess.run(
            ["/usr/bin/openssl", "genrsa", "-out", str(self.private_key), "2048"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.private_key.chmod(0o600)
        subprocess.run(
            ["/usr/bin/openssl", "rsa", "-in", str(self.private_key),
             "-pubout", "-out", str(self.public_key)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        installer = self.bundle / "install.sh"
        installer.write_text(
            "#!/bin/bash\nset -eu\nprintf '%s' \"$CB_RELEASE_SEQUENCE\" > \"$CB_RELEASE_TEST_MARKER\"\n"
        )
        installer.chmod(0o755)
        self.release_dir = self.root / "public"
        self.state_dir = self.root / "state"
        self.marker = self.root / "marker"
        self.old_marker = os.environ.get("CB_RELEASE_TEST_MARKER")
        os.environ["CB_RELEASE_TEST_MARKER"] = str(self.marker)

    def tearDown(self):
        if self.old_marker is None:
            os.environ.pop("CB_RELEASE_TEST_MARKER", None)
        else:
            os.environ["CB_RELEASE_TEST_MARKER"] = self.old_marker
        self.temporary.cleanup()

    def publish(self, sequence):
        return PUBLISHER.publish(
            self.bundle, self.release_dir, self.private_key, sequence,
            "/usr/bin/openssl",
        )

    def client(self, base_url, now=lambda: 1_000_000):
        config = self.root / "config.json"
        config.write_text(json.dumps({"audit": False, "base_url": base_url}))
        return CLIENT.ReleaseClient(
            config, self.public_key, self.state_dir, "/usr/bin/openssl", now=now,
        )

    def test_signed_release_applies_once(self):
        self.publish(1)
        self.assertTrue((self.release_dir / "manifests/release-00000001.json").is_file())
        self.assertTrue((self.release_dir / "manifests/release-00000001.sig").is_file())
        with ReleaseServer(self.release_dir) as base_url:
            client = self.client(base_url)
            self.assertEqual(client.run(), "applied")
            self.assertEqual(self.marker.read_text(), "1")
            self.assertEqual(client.run(), "up-to-date")

    def test_corrupt_signature_is_rejected(self):
        self.publish(1)
        signature = self.release_dir / "current.sig"
        signature.write_bytes(signature.read_bytes()[:-1] + b"x")
        with ReleaseServer(self.release_dir) as base_url:
            self.assertEqual(self.client(base_url).run(), "rejected")
        self.assertFalse(self.marker.exists())

    def test_signature_with_trailing_bytes_is_rejected(self):
        self.publish(1)
        signature = self.release_dir / "current.sig"
        signature.write_bytes(signature.read_bytes() + b"tampered")
        with ReleaseServer(self.release_dir) as base_url:
            self.assertEqual(self.client(base_url).run(), "rejected")
        self.assertFalse(self.marker.exists())

    def test_payload_mismatch_is_rejected(self):
        manifest = self.publish(1)
        payload = self.release_dir / manifest["payload"]
        payload.write_bytes(payload.read_bytes() + b"tampered")
        with ReleaseServer(self.release_dir) as base_url:
            self.assertEqual(self.client(base_url).run(), "rejected")
        self.assertFalse(self.marker.exists())

    def test_lower_sequence_is_rejected_after_newer_release(self):
        self.publish(1)
        old_manifest = (self.release_dir / "current.json").read_bytes()
        old_signature = (self.release_dir / "current.sig").read_bytes()
        with ReleaseServer(self.release_dir) as base_url:
            client = self.client(base_url, now=lambda: 1_000_000)
            self.assertEqual(client.run(), "applied")
            self.publish(2)
            self.assertEqual(client.run(), "applied")
            (self.release_dir / "current.sig").write_bytes(old_signature)
            (self.release_dir / "current.json").write_bytes(old_manifest)
            self.assertEqual(client.run(), "rejected")
        state = json.loads((self.state_dir / "state.json").read_text())
        self.assertEqual(state["last_sequence"], 2)
        self.assertEqual(self.marker.read_text(), "2")

    def test_unsafe_archive_path_is_rejected(self):
        archive_path = self.root / "unsafe.tar.gz"
        with tarfile.open(archive_path, "w:gz") as archive:
            info = tarfile.TarInfo("../escape")
            content = b"escape"
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
        destination = self.root / "extract"
        destination.mkdir()
        with self.assertRaisesRegex(CLIENT.ReleaseError, "unsafe archive path"):
            CLIENT.safe_extract(archive_path, destination)
        self.assertFalse((self.root / "escape").exists())

    def test_publisher_rejects_sequence_reuse(self):
        self.publish(1)
        with self.assertRaisesRegex(PUBLISHER.PublishError, "must exceed"):
            self.publish(1)

    def test_corrupt_state_fails_closed(self):
        self.publish(1)
        self.state_dir.mkdir()
        (self.state_dir / "state.json").write_text("not json")
        with ReleaseServer(self.release_dir) as base_url:
            with self.assertRaisesRegex(CLIENT.ReleaseError, "refusing rollback"):
                self.client(base_url).run()
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
