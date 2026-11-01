import functools
from http.server import ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from serve import PreviewHandler


class QuietHandler(PreviewHandler):
    def log_message(self, *_args):
        pass


class PreviewTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.audio = bytes(range(256)) * 10
        Path(cls.directory.name, "call.mp3").write_bytes(cls.audio)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=cls.directory.name))
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/call.mp3?v=contenthash"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join()
        cls.directory.cleanup()

    def test_full_audio_advertises_seeking(self):
        with urlopen(self.url) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Accept-Ranges"], "bytes")
            self.assertEqual(response.read(), self.audio)

    def test_ranges_return_exact_bytes_and_lengths(self):
        for header, start, end in [("bytes=100-199", 100, 199), ("bytes=2500-", 2500, 2559), ("bytes=-25", 2535, 2559), ("bytes=2550-9999", 2550, 2559)]:
            with self.subTest(header=header), urlopen(Request(self.url, headers={"Range": header})) as response:
                self.assertEqual(response.status, 206)
                self.assertEqual(response.headers["Content-Range"], f"bytes {start}-{end}/2560")
                self.assertEqual(int(response.headers["Content-Length"]), end - start + 1)
                self.assertEqual(response.read(), self.audio[start:end + 1])

    def test_head_range_and_out_of_bounds(self):
        with urlopen(Request(self.url, method="HEAD", headers={"Range": "bytes=100-199"})) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers["Content-Length"], "100")
            self.assertEqual(response.read(), b"")
        for header in ["bytes=9999-", "bytes=200-100", "bytes=-0"]:
            with self.subTest(header=header), self.assertRaises(HTTPError) as caught:
                urlopen(Request(self.url, headers={"Range": header}))
            self.assertEqual(caught.exception.code, 416)
            self.assertEqual(caught.exception.headers["Content-Range"], "bytes */2560")
            caught.exception.close()

    def test_if_range_uses_a_complete_response_without_a_validator_match(self):
        with urlopen(Request(self.url, headers={"Range": "bytes=100-199", "If-Range": '"old-version"'})) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), self.audio)


if __name__ == "__main__":
    unittest.main()
