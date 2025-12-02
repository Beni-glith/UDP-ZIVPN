#!/usr/bin/env python3
"""Local HTTP API for managing UDP VPN user data without external panel."""
import argparse
import base64
import json
import os
import random
import string
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse


def load_db(path):
    if not os.path.exists(path):
        return {"users": []}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"users": []}


def save_db(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def random_string(length=6):
    alphabet = string.ascii_lowercase + string.digits
    return "".join(random.choice(alphabet) for _ in range(length))


def now_ts():
    return int(time.time())


class LocalAPIHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return  # silence default logging

    def _auth_failed(self):
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"error":"Unauthorized"}')

    def _parse_query(self):
        parsed = urlparse(self.path)
        return parsed.path.lstrip("/"), {k: v[0] for k, v in parse_qs(parsed.query).items()}

    def _write_json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _check_auth(self):
        if not self.server.api_token:
            return True
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {self.server.api_token}"

    def do_GET(self):  # noqa: N802
        if not self._check_auth():
            return self._auth_failed()

        path, params = self._parse_query()
        db = load_db(self.server.db_path)
        users = db.get("users", [])

        if path == "ping":
            return self._write_json({"status": "ok", "mode": "local"})
        if path == "info":
            summary = {
                "mode": "local",
                "user_count": len(users),
                "db_path": self.server.db_path,
            }
            return self._write_json(summary)
        if path == "users":
            return self._write_json({"users": users, "count": len(users)})
        if path == "add":
            username = params.get("user")
            password = params.get("pass")
            days = int(params.get("days", 0))
            if not username or not password or days <= 0:
                return self._write_json({"error": "user, pass, days diperlukan"}, status=400)
            if any(u["user"] == username for u in users):
                return self._write_json({"error": "User sudah ada"}, status=400)
            expire = now_ts() + days * 86400
            users.append({"user": username, "pass": password, "expire_at": expire})
            db["users"] = users
            save_db(self.server.db_path, db)
            return self._write_json({"message": "User ditambahkan", "user": username, "expire_at": expire})
        if path == "trial":
            minutes = int(params.get("minutes", 0))
            if minutes <= 0:
                return self._write_json({"error": "minutes harus > 0"}, status=400)
            username = f"trial{random_string(4)}"
            password = random_string(8)
            expire = now_ts() + minutes * 60
            users.append({"user": username, "pass": password, "expire_at": expire, "trial": True})
            db["users"] = users
            save_db(self.server.db_path, db)
            return self._write_json({"message": "Trial dibuat", "user": username, "pass": password, "expire_at": expire})
        if path == "delete":
            username = params.get("user")
            if not username:
                return self._write_json({"error": "user diperlukan"}, status=400)
            new_users = [u for u in users if u.get("user") != username]
            if len(new_users) == len(users):
                return self._write_json({"error": "User tidak ditemukan"}, status=404)
            db["users"] = new_users
            save_db(self.server.db_path, db)
            return self._write_json({"message": "User dihapus", "user": username})
        if path == "renew":
            username = params.get("user")
            days = int(params.get("days", 0))
            if not username or days <= 0:
                return self._write_json({"error": "user dan days diperlukan"}, status=400)
            for u in users:
                if u.get("user") == username:
                    u["expire_at"] = max(u.get("expire_at", now_ts()), now_ts()) + days * 86400
                    save_db(self.server.db_path, db)
                    return self._write_json({"message": "User diperpanjang", "user": username, "expire_at": u["expire_at"]})
            return self._write_json({"error": "User tidak ditemukan"}, status=404)
        if path == "changepass":
            username = params.get("user")
            password = params.get("pass")
            if not username or not password:
                return self._write_json({"error": "user dan pass diperlukan"}, status=400)
            for u in users:
                if u.get("user") == username:
                    u["pass"] = password
                    save_db(self.server.db_path, db)
                    return self._write_json({"message": "Password diperbarui", "user": username})
            return self._write_json({"error": "User tidak ditemukan"}, status=404)
        if path == "backup":
            payload = json.dumps(db).encode()
            backup_id = base64.urlsafe_b64encode(payload).decode()
            return self._write_json({"backup_id": backup_id, "user_count": len(users)})
        if path == "restore":
            backup_id = params.get("id")
            if not backup_id:
                return self._write_json({"error": "id diperlukan"}, status=400)
            try:
                raw = base64.urlsafe_b64decode(backup_id.encode())
                restored = json.loads(raw)
            except (ValueError, json.JSONDecodeError):
                return self._write_json({"error": "backup tidak valid"}, status=400)
            save_db(self.server.db_path, restored)
            return self._write_json({"message": "Backup dipulihkan", "user_count": len(restored.get("users", []))})

        return self._write_json({"error": "endpoint tidak ditemukan"}, status=404)


class LocalAPIServer(HTTPServer):
    def __init__(self, server_address, handler_class, db_path, api_token):
        super().__init__(server_address, handler_class)
        self.db_path = db_path
        self.api_token = api_token


def parse_args():
    parser = argparse.ArgumentParser(description="Local API server for UDP ZIVPN manager")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8686, help="Port untuk API lokal (default: 8686)")
    parser.add_argument("--db", default="/etc/zivpn-udp/local_api_db.json", help="Path database lokal")
    parser.add_argument("--token", default="", help="Token Bearer opsional untuk autentikasi")
    return parser.parse_args()


def main():
    args = parse_args()
    server = LocalAPIServer((args.host, args.port), LocalAPIHandler, args.db, args.token)
    print(f"[local-api] Berjalan di http://{args.host}:{args.port} (DB: {args.db})")
    if args.token:
        print("[local-api] Mode autentikasi token aktif")
    server.serve_forever()


if __name__ == "__main__":
    main()
