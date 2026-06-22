#!/usr/bin/env python3
"""VoiceDrop WeChat publish relay — runs on the Tokyo VPS (66.42.45.128), whose
IP is whitelisted on the 公众号 account, so it calls api.weixin.qq.com DIRECTLY
(no proxy hop). The Cloudflare Function POSTs the article + WeChat creds here and
awaits the REAL result, so the app can finally show success/errcode synchronously
instead of the old fire-and-forget GitHub-Action dispatch.

Dumb relay by design: it holds NO R2 / FILES_TOKEN, never touches R2. It receives
appid/secret per request (kept in memory, never logged), talks to WeChat, and
returns the mutated article (with wechatMediaId filled) + the final thumb id; the
Function persists those back to R2.

Reachable ONLY through a Cloudflare Tunnel (cloudflared → 127.0.0.1:PORT); every
request must carry X-Relay-Secret == $WECHAT_RELAY_SECRET (constant-time check).

  POST /publish  {appid, secret, thumb_media_id?, article:{articles:[{title,body,wechatMediaId?}]}}
       -> 200 {ok:true,  article, thumb_media_id, created, updated}
       -> 200 {ok:false, errcode, errmsg}        (a real WeChat error — relayed verbatim)
       -> 401 wrong/absent secret · 400 bad body · 500 unexpected
  GET  /health   -> 200 ok

Env: WECHAT_RELAY_SECRET (required), PORT (default 8848). FILES_TOKEN is set to a
dummy below so `import mine` (which hard-reads it at module load) doesn't crash —
the relay never uses it.
"""
import os, re, json, hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# mine.py hard-reads FILES_TOKEN at import; the relay never uses it (no R2). Set a
# dummy BEFORE importing so the module loads. WECHAT_PROXY stays unset → mine's
# WeChat opener goes direct, which is correct here (already on the whitelisted IP).
os.environ.setdefault("FILES_TOKEN", "unused-by-relay")
import mine  # noqa: E402  (must follow the setdefault above)

RELAY_SECRET = os.environ.get("WECHAT_RELAY_SECRET", "")
PORT = int(os.environ.get("PORT", "8848"))
MAX_BODY = 4 * 1024 * 1024   # 4 MB cap — articles are small

_ERRCODE_RE = re.compile(r"errcode['\"]?\s*[:=]\s*(-?\d+)")
_ERRMSG_RE = re.compile(r"errmsg['\"]?\s*[:=]\s*['\"]([^'\"]*)['\"]")


def _wechat_err(exc):
    """Pull a real WeChat {errcode, errmsg} out of a RuntimeError raised by mine.py
    (its messages embed the WeChat response dict). Falls back to the raw string."""
    s = str(exc)
    code = _ERRCODE_RE.search(s)
    msg = _ERRMSG_RE.search(s)
    return {
        "errcode": int(code.group(1)) if code else None,
        "errmsg": msg.group(1) if msg else s,
    }


def _publish(payload):
    """Run the synchronous WeChat publish and return the JSON-able result dict."""
    appid = payload.get("appid")
    secret = payload.get("secret")
    article = payload.get("article") or {}
    if not appid or not secret or not isinstance(article.get("articles"), list):
        raise ValueError("missing appid/secret/article.articles")

    token = mine.wechat_access_token(appid, secret)
    # Reuse the cached thumb if given, else upload a placeholder cover. Box it so a
    # mid-run cover re-upload (stale material) is captured to return to the caller.
    thumb = [payload.get("thumb_media_id") or mine._upload_wechat_cover(token)]

    def make_thumb():
        thumb[0] = mine._upload_wechat_cover(token)
        return thumb[0]

    created, updated = mine.sync_wechat_drafts(token, article, thumb[0], make_thumb=make_thumb)
    return {
        "ok": True,
        "article": article,          # mutated in place: each item now has wechatMediaId
        "thumb_media_id": thumb[0],
        "created": created,
        "updated": updated,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "wechat-relay/1"

    def _send(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/publish":
            return self._send(404, {"error": "not found"})
        # Auth: constant-time compare of the shared secret.
        got = self.headers.get("X-Relay-Secret", "")
        if not RELAY_SECRET or not hmac.compare_digest(got, RELAY_SECRET):
            return self._send(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return self._send(400, {"error": "bad content-length"})
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self._send(400, {"error": "invalid json"})

        try:
            return self._send(200, _publish(payload))
        except ValueError as e:
            return self._send(400, {"error": str(e)})
        except RuntimeError as e:
            # A real WeChat-side failure — relay the actual errcode/errmsg (HTTP 200,
            # ok:false) so the Function/app can show it.
            return self._send(200, {"ok": False, **_wechat_err(e)})
        except Exception as e:  # noqa: BLE001 — last-resort guard
            return self._send(500, {"error": "relay error", "detail": str(e)[:200]})

    def log_message(self, fmt, *args):
        # Quiet access log; never prints request bodies (which hold creds).
        print(f"[relay] {self.address_string()} {fmt % args}", flush=True)


def main():
    if not RELAY_SECRET:
        raise SystemExit("WECHAT_RELAY_SECRET must be set")
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[relay] listening on 127.0.0.1:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
