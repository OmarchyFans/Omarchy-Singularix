#!/usr/bin/env python3
"""A tiny fake of https://api.omarchy.fans/v1 for the cloud section of tests/run.sh.

    python3 fake_api.py <port> <request-log.jsonl>

Implements just what lib/runtimes/cloud.sh touches, with the response shapes from docs/API.md:
device flow (token pending twice, then ok), agents (create → provisioning → sleeping after
two polls; wake/sleep/console-ticket/destroy/events), /me, /pricing, /gpu/catalog, /twins (create/keepalive).
Every request is appended to the log as {method, path, auth, body} so the test can assert
what the client sent. Stdlib only, in-memory state, single process.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(sys.argv[1])
LOG = sys.argv[2]
TOKEN = "ofc_test_token_123"

state = {"token_polls": 0, "agents": {}, "twins": {}, "seq": 0}

PRICING = {
    "tiers": [
        {"id": "fan", "name": "Fan", "price_month": 0, "quotas": {"hosted_agents": 1, "awake_hours": 10, "storage_gb": 1, "gpu_access": False}},
        {"id": "plus", "name": "Plus", "price_month": 5, "quotas": {"hosted_agents": 3, "awake_hours": 60, "storage_gb": 10, "gpu_access": True}},
    ],
    "overage": {"awake_hour": 0.1, "storage_gb_month": 0.05},
}
CATALOG = [{"id": "l4", "name": "Compact 24 GB", "vram_gb": 24, "price_hour": 1.0, "price_hour_discounted": 0.9,
            "price_minute": 0.015, "discount": 0.1, "suggested_model": "Qwen/Qwen3-8B"}]


def agent_view(a):
    return {k: v for k, v in a.items() if k not in ("secrets", "polls")}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence
        pass

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _err(self, code, ecode, msg=""):
        self._send(code, {"error": {"code": ecode, "message": msg or ecode}})

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            return {}

    def _log(self, method, path, body):
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"method": method, "path": path, "auth": self.headers.get("Authorization", ""), "body": body}) + "\n")

    def _authed(self):
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")

    def handle_any(self, method):
        u = urlparse(self.path)
        path = u.path
        body = self._body() if method != "GET" else {}
        self._log(method, self.path, body)
        parts = [p for p in path.split("/") if p]   # ["v1", "agents", "agt_1", "wake"]
        if not parts or parts[0] != "v1":
            return self._err(404, "not_found")
        parts = parts[1:]

        # public
        if parts == ["pricing"] and method == "GET":
            return self._send(200, PRICING)
        if parts == ["gpu", "catalog"] and method == "GET":
            return self._send(200, {"catalog": CATALOG})
        if parts == ["device", "code"] and method == "POST":
            if not body.get("client_name"):
                return self._err(400, "bad_request", "client_name required")
            return self._send(200, {"device_code": "dc_test", "user_code": "FANS-7Q2K",
                                    "verification_uri": "https://omarchy.fans/device",
                                    "verification_uri_complete": "https://omarchy.fans/device?user_code=FANS-7Q2K",
                                    "expires_in": 900, "interval": 5})
        if parts == ["device", "token"] and method == "POST":
            if body.get("device_code") != "dc_test":
                return self._err(400, "invalid_grant")
            state["token_polls"] += 1
            if state["token_polls"] <= 2:
                return self._err(428, "authorization_pending")
            return self._send(200, {"token": TOKEN, "token_id": "tok_1",
                                    "org": {"id": "org_1", "slug": "milton", "name": "Milton", "tier": "plus"},
                                    "user": {"login": "milton"}})

        # everything below needs the bearer token
        if not self._authed():
            return self._err(401, "unauthorized", "missing or invalid token")

        if parts == ["me"] and method == "GET":
            return self._send(200, {"user": {"id": "usr_1", "login": "milton"},
                                    "org": {"id": "org_1", "slug": "milton", "name": "Milton", "tier": "plus"},
                                    "orgs": [], "quotas": {"hosted_agents": 3, "awake_hours": 60},
                                    "usage": {"hosted_agents": len(state["agents"]), "awake_hours": 1.5}})
        if parts == ["tokens", "tok_1"] and method == "DELETE":
            return self._send(200, {"ok": True})

        if parts == ["agents"] and method == "GET":
            return self._send(200, {"agents": [agent_view(a) for a in state["agents"].values() if a["state"] != "destroyed"]})
        if parts == ["agents"] and method == "POST":
            if not body.get("name"):
                return self._err(400, "bad_request", "name required")
            if "home" in body or "home_tgz" in body:
                return self._err(400, "bad_request", "the home must not be uploaded")
            state["seq"] += 1
            aid = f"agt_{state['seq']}"
            a = {"id": aid, "name": body["name"], "agent_kind": body.get("agent_kind", "hermes"),
                 "model": body.get("model"), "provider": body.get("provider"), "base_url": body.get("base_url"),
                 "role": body.get("role", "worker"), "skills": body.get("skills", []), "size": body.get("size", "s"),
                 "state": "provisioning", "state_message": None, "awake_since": None, "storage_bytes": 0,
                 "console": {"ws": f"ws://127.0.0.1:{PORT}/v1/agents/{aid}/console"},
                 "usage": {"awake_hours_period": 0, "prompt_tokens": 0, "output_tokens": 0, "cost_usd": 0},
                 "secrets": body.get("secrets", {}), "polls": 0}
            state["agents"][aid] = a
            return self._send(201, agent_view(a))
        if len(parts) >= 2 and parts[0] == "agents":
            a = state["agents"].get(parts[1])
            if not a:
                return self._err(404, "not_found", "no such agent")
            if len(parts) == 2 and method == "GET":
                a["polls"] += 1
                if a["state"] == "provisioning" and a["polls"] >= 3:
                    a["state"] = "sleeping"
                out = agent_view(a)
                out["events"] = [{"at": "2026-09-09T00:00:00Z", "kind": "created", "message": "Agent created"}]
                out["secret_keys"] = sorted(a["secrets"].keys())
                return self._send(200, out)
            if len(parts) == 3 and method == "POST":
                op = parts[2]
                if op == "wake":
                    if a["state"] == "provisioning":
                        return self._err(409, "not_ready", "still provisioning")
                    a["state"] = "awake"
                    a["awake_since"] = "2026-09-09T00:00:00Z"
                    return self._send(200, agent_view(a))
                if op == "sleep":
                    a["state"] = "sleeping"
                    a["awake_since"] = None
                    return self._send(200, agent_view(a))
                if op == "console-ticket":
                    return self._send(201, {"ticket": "oct_test_ticket", "expires_in": 60})
                if op == "destroy":
                    a["state"] = "destroyed"
                    return self._send(200, {"ok": True, "id": a["id"], "state": "destroyed"})
            if len(parts) == 3 and parts[2] == "events" and method == "GET":
                return self._send(200, {"events": [{"at": "2026-09-09T00:00:00Z", "kind": "created", "message": "Agent created"}]})

        if parts == ["twins"] and method == "POST":
            state["seq"] += 1
            tid = f"twn_{state['seq']}"
            state["twins"][tid] = {"id": tid, "hostname": body.get("hostname"), "state": "provisioning"}
            return self._send(201, {"twin": state["twins"][tid], "ssh": {"host": "twin", "port": 2222, "user": "twin"},
                                    "console_url": f"https://omarchy.fans/app/twins/{tid}"})
        if len(parts) == 3 and parts[0] == "twins" and parts[2] == "keepalive" and method == "POST":
            return self._send(200, {"ok": True, "expire": body.get("expire")})

        return self._err(404, "not_found", f"{method} {path}")


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    srv.daemon_threads = True
    srv.serve_forever()
