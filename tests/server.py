import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, payload, extra_headers=None):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/slow"):
            time.sleep(3)
        if self.path.startswith("/cookie"):
            self._reply(200, {"method": "GET", "path": self.path}, {"Set-Cookie": "tuiter_test=1; Path=/"})
            return
        self._reply(200, {"method": "GET", "path": self.path, "cookie": self.headers.get("Cookie")})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self._reply(201, {"method": "POST", "echo": self.rfile.read(n).decode()})

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", 8999), Handler).serve_forever()
