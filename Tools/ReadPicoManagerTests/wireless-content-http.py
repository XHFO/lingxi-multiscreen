#!/usr/bin/env python3
"""Production HTTPClient contract test. Own localhost server/temp data only; no real device."""
import hashlib
import http.server
import json
import pathlib
import struct
import subprocess
import sys
import threading
import urllib.parse
import zlib


def drawing():
    data = bytearray(12 + 49168)
    struct.pack_into("<III", data, 0, 0x31535058, 49168, 0)
    struct.pack_into("<IHHHH", data, 12, 0x314E4450, 1, 684, 1216, 1)
    struct.pack_into("<HHBB", data, 28, 40, 40, 3, 1)
    struct.pack_into("<I", data, 8, zlib.crc32(data[12:]))
    return bytes(data)


class Fixture(http.server.BaseHTTPRequestHandler):
    files = {"books/第一本.txt": b"first", "books/第二本.txt": b"second", "apps/data/drawing-notes/board01.dat": drawing()}
    mode = "normal"
    events = []

    def log_message(self, *_):
        pass

    def reply(self, code, value, content_type="application/json"):
        data = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        url = urllib.parse.urlsplit(self.path)
        assert url.path == "/_fixture"
        type(self).mode = urllib.parse.parse_qs(url.query)["mode"][0]
        self.reply(200, {"ok": True})

    def dispatch(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        path = query.get("path", [""])[0]
        type(self).events.append({"method": self.command, "route": url.path, "path": path})
        assert not url.fragment and "key=" not in url.query
        if url.path == "/leak":
            raise AssertionError("pairing header was redirected")
        if self.headers.get("X-Pico-Setup-Key") != "a" * 32 or self.mode == "expired":
            return self.reply(401, {"ok": False})
        if url.path == "/api/manage/pico/status":
            return self.reply(200, {"protocol": 1, "canvas": {"supported": True, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": 420000}, "content": {"supported": True, "max_bytes": 268435456, "max_page_items": 2}})
        if self.mode == "busy":
            return self.reply(503, {"ok": False})
        if url.path == "/api/manage/pico/files" and self.command == "GET":
            offset = int(query["offset"][0])
            limit = int(query["limit"][0])
            assert limit == 2
            names = sorted(self.files)
            page = [{"path": p, "title": pathlib.PurePosixPath(p).stem, "kind": "drawing" if p.endswith(".dat") else "note" if p.startswith("books/灵犀笔记-") else "book", "bytes": len(self.files[p]), "valid": True} for p in names[offset:offset + limit]]
            if self.mode == "badlist":
                page[0]["path"] = "../settings.dat"
            if self.mode == "duplicate" and offset:
                page[0]["path"] = names[0]
            total = len(names) + (1 if self.mode == "changedtotal" and offset else 0)
            return self.reply(200, {"ok": True, "items": page, "offset": offset, "total": total})
        if url.path == "/api/manage/pico/files" and self.command == "PUT":
            assert self.headers.get("Content-Type") == "application/octet-stream"
            data = self.rfile.read(int(self.headers["Content-Length"]))
            sha = hashlib.sha256(data).hexdigest()
            assert self.headers.get("X-Pico-Content-SHA256") == sha
            if path in self.files and query["replace"][0] != "1":
                return self.reply(409, {"ok": False})
            self.files[path] = data
            return self.reply(200, {"ok": True, "path": path, "bytes": len(data), "sha256": "0" * 64 if self.mode == "badreceipt" else sha})
        if url.path == "/api/manage/pico/files" and self.command == "DELETE":
            assert path in self.files and path.startswith(("books/", "fonts/", "apps/games/", "apps/tools/"))
            del self.files[path]
            return self.reply(200, {"ok": True, "path": path})
        if url.path == "/api/manage/pico/file":
            if self.mode == "redirect":
                self.send_response(302)
                self.send_header("Location", "/leak")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if path not in self.files:
                return self.reply(404, {"ok": False})
            data = self.files[path]
            if query.get("metadata") == ["1"]:
                return self.reply(200, {"ok": True, "path": "wrong" if self.mode == "badmetadata" else path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
            return self.reply(200, data, "application/octet-stream")
        raise AssertionError((self.command, self.path))

    do_GET = dispatch
    do_PUT = dispatch
    do_DELETE = dispatch


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
try:
    result = subprocess.run([sys.argv[1], f"http://127.0.0.1:{server.server_port}"], text=True, capture_output=True)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    assert result.returncode == 0, result.returncode
    assert not any(e["route"] == "/leak" for e in Fixture.events)
    report = {"passed": True, "transport": "actual localhost HTTP", "hardware": False, "requests": len(Fixture.events), "events": Fixture.events}
    pathlib.Path(sys.argv[2]).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
finally:
    server.shutdown()
    server.server_close()
