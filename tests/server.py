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
        if self.path.startswith("/echo-headers"):
            self._reply(200, {"headers": dict(self.headers)})
            return
        if self.path.startswith("/pages"):
            n = 0
            import re
            m = re.search(r"[?&]n=(\d+)", self.path)
            if m:
                n = int(m.group(1))
            if n < 2:
                self._reply(
                    200,
                    [n, n + 1],
                    {"Link": f'<http://127.0.0.1:8999/pages?n={n+1}>; rel="next", <http://127.0.0.1:8999/other>; rel="prev"'},
                )
            else:
                self._reply(200, [n, n + 1])
            return
        if self.path.startswith("/fail"):
            self._reply(500, {"error": "boom"})
            return
        if self.path.startswith("/sse"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")  # end-of-body signal: curl -N can terminate
            self.end_headers()
            for i in range(3):
                self.wfile.write(f"data: {{n:{i}}}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.3)
            return
        self._reply(200, {"method": "GET", "path": self.path, "cookie": self.headers.get("Cookie")})

    def do_POST(self):
        if self.path.startswith("/token"):
            body = {"access_token": "oauth_token_123", "expires_in": 3600}
            if self.headers.get("Content-Type") == "application/json":
                self._reply(200, body)
            else:
                self._reply(200, body)
            return
        n = int(self.headers.get("Content-Length", 0))
        self._reply(201, {"method": "POST", "echo": self.rfile.read(n).decode()})

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", 8999), Handler).serve_forever()
