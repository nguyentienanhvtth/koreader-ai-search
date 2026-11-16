#!/usr/bin/env python3
"""Mock API for the KOReader "contextdict" plugin.

Returns a fake but correctly-shaped answer so you can test the plugin on the
Kindle before the real API exists. It prints every request it receives, so
you can see exactly what the Kindle sends (word, sentence, context...).

Run:   python3 tools/mock_server.py            (listens on 0.0.0.0:8787)
Then on the Kindle set the API address to  http://<your-Mac-LAN-IP>:8787/explain
"""
import json
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._send(400, {"error": "body is not valid JSON"})

        print("\n=== request from", self.client_address[0], "===")
        print(json.dumps(req, ensure_ascii=False, indent=2))
        if self.headers.get("Authorization"):
            print("Authorization header present")

        word = (req.get("word") or "").strip()
        if not word:
            return self._send(400, {"error": "missing 'word'"})
        sentence = req.get("sentence") or ""

        self._send(200, {
            "word": word,
            "lemma": word.lower(),
            "ipa": "/mɒk/",
            "part_of_speech": "noun",
            "meaning_vi": f"(MOCK) Nghĩa tiếng Việt của “{word}” trong câu này.",
            "meaning_en": f"(MOCK) The meaning of “{word}” as used in this sentence.",
            "explanation_vi": (
                f"(MOCK) Server đã nhận được câu: “{sentence}”" if sentence
                else "(MOCK) Server không nhận được ngữ cảnh."
            ),
            "sentence_vi": "(MOCK) Bản dịch tiếng Việt của câu gốc.",
            "other_meanings": ["(MOCK) một nghĩa khác", "(MOCK) thêm một nghĩa nữa"],
            "examples": [
                {"en": f"(MOCK) An example with {word}.", "vi": "(MOCK) Một câu ví dụ."},
            ],
        })

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packet is sent: this only asks the OS which local address the
        # default route uses (a 10.x target could match a VPN/bridge route).
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


if __name__ == "__main__":
    print(f"Mock API running. On the Kindle use:  http://{lan_ip()}:{PORT}/explain")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
