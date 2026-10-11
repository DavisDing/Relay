"""Loopback-only fixture. No request headers or bodies are logged."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

hits = 0

class QuietHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, code, body=b"", location=None):
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class OtherOrigin(QuietHandler):
    def do_GET(self):
        global hits
        if self.path == "/count":
            self.respond(200, str(hits).encode())
        else:
            hits += 1
            self.respond(200, b"unexpected")

other = ThreadingHTTPServer(("127.0.0.1", 0), OtherOrigin)
other_url = "http://127.0.0.1:" + str(other.server_port)

class Origin(QuietHandler):
    def do_GET(self):
        if self.path == "/same":
            self.respond(302, location="/authenticated")
        elif self.path == "/authenticated":
            allowed = self.headers.get("Authorization") == "fixture-token-only" and self.headers.get("Pipio-User") == "fixture-id-only"
            self.respond(200 if allowed else 401, b"authenticated" if allowed else b"missing")
        elif self.path == "/cross":
            self.respond(302, location=other_url + "/leak")
        elif self.path == "/multi":
            self.respond(302, location="/cross")
        else:
            self.respond(500)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.respond(303, location="/authenticated")

origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
threading.Thread(target=other.serve_forever, daemon=True).start()
threading.Thread(target=origin.serve_forever, daemon=True).start()
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(["http://127.0.0.1:" + str(origin.server_port), other_url], output)
threading.Event().wait()
