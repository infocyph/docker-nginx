#!/usr/bin/env python3
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "11434"))
STREAM_DELAY_SECONDS = float(os.environ.get("STREAM_DELAY_SECONDS", "3"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return raw.decode("utf-8", errors="replace")

    def _metadata(self, body=None, chunk=None):
        data = {
            "path": self.path,
            "host": self.headers.get("Host", ""),
            "forwarded_host": self.headers.get("X-Forwarded-Host", ""),
            "forwarded_proto": self.headers.get("X-Forwarded-Proto", ""),
            "forwarded_port": self.headers.get("X-Forwarded-Port", ""),
            "request_id_present": bool(self.headers.get("X-Request-ID", "")),
            "connection": self.headers.get("Connection", ""),
            "upgrade": self.headers.get("Upgrade", ""),
        }
        if body is not None:
            data["request"] = body
        if chunk is not None:
            data["chunk"] = chunk
        return data

    def _json_bytes(self, value):
        return json.dumps(value, separators=(",", ":")).encode("utf-8")

    def _send_json(self, value, status=200):
        payload = self._json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def _start_chunked(self, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

    def _write_chunk(self, payload):
        self.wfile.write(f"{len(payload):X}\r\n".encode("ascii"))
        self.wfile.write(payload)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _finish_chunked(self):
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def _stream_native(self, body):
        self._start_chunked("application/x-ndjson")
        first = self._json_bytes(self._metadata(body=body, chunk=1)) + b"\n"
        self._write_chunk(first)
        time.sleep(STREAM_DELAY_SECONDS)
        self._write_chunk(self._json_bytes({"chunk": 2, "done": True}) + b"\n")
        self._finish_chunked()

    def _stream_openai(self, body):
        self._start_chunked("text/event-stream")
        first = b"data: " + self._json_bytes(self._metadata(body=body, chunk=1)) + b"\n\n"
        self._write_chunk(first)
        time.sleep(STREAM_DELAY_SECONDS)
        self._write_chunk(b"data: [DONE]\n\n")
        self._finish_chunked()

    def do_GET(self):
        if self.path == "/api/tags":
            self._send_json({"models": [{"name": "mock:latest"}]})
            return
        if self.path == "/api/version":
            self._send_json({"version": "mock"})
            return
        self._send_json(self._metadata())

    def do_POST(self):
        body = self._read_body()
        if self.path in ("/api/chat", "/api/generate"):
            self._stream_native(body)
            return
        if self.path.startswith("/v1/"):
            self._stream_openai(body)
            return
        self._send_json(self._metadata(body=body))


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
