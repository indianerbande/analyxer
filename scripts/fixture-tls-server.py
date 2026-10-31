#!/usr/bin/env python3
"""Explicit local fixture endpoint; never logs payloads and binds loopback only."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import ssl

ROOT = Path(__file__).resolve().parent.parent

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if self.path != '/fixture' or not 0 < size <= 4096:
            self.send_error(400)
            return
        payload = json.loads(self.rfile.read(size))
        if payload.get('synthetic') is not True:
            self.send_error(400)
            return
        data = json.dumps({'synthetic': True, 'reply': 'fixture-response', 'echo': payload['message']}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 18443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(ROOT / '.local/tls/cert.pem', ROOT / '.local/tls/key.pem')
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print('Synthetic TLS fixture: https://127.0.0.1:18443/fixture', flush=True)
    server.serve_forever()
