#!/usr/bin/env python3
"""Local static preview with single byte ranges for native audio seeking."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re


class PreviewHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        if getattr(self, "range_file", False):
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_head(self):
        self.byte_range = None
        path = self.translate_path(self.path)
        self.range_file = os.path.isfile(path)
        header = self.headers.get("Range")
        if not self.range_file or not header or self.headers.get("If-Range"):
            return super().send_head()

        match = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
        if not match or not any(match.groups()):
            return super().send_head()

        try:
            source = open(path, "rb")
        except OSError:
            return super().send_head()
        stat = os.fstat(source.fileno())
        size = stat.st_size
        first, last = match.groups()
        if first:
            start = int(first)
            end = min(int(last), size - 1) if last else size - 1
        else:
            start = max(0, size - int(last))
            end = size - 1

        if start >= size or start > end:
            source.close()
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None

        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Last-Modified", self.date_time_string(stat.st_mtime))
        self.end_headers()
        source.seek(start)
        self.byte_range = (start, end)
        return source

    def copyfile(self, source, outputfile):
        if self.byte_range is None:
            return super().copyfile(source, outputfile)
        start, end = self.byte_range
        remaining = end - start + 1
        while remaining:
            data = source.read(min(64 * 1024, remaining))
            if not data:
                break
            outputfile.write(data)
            remaining -= len(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", nargs="?", type=int, default=4990)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--directory", type=Path, default=Path(__file__).parent / "_site")
    args = parser.parse_args()
    with ThreadingHTTPServer((args.bind, args.port), partial(PreviewHandler, directory=args.directory)) as server:
        print(f"Serving preview at http://{args.bind}:{args.port}/", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
