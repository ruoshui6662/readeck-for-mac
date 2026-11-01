#!/usr/bin/env python3
"""Local Readeck-shaped server for manual UI checks. Token: demo-token."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import secrets
from datetime import datetime, timezone
from urllib.parse import urlparse

ARTICLE_ID = "AaaabbbbCCCCdddd1234"
BOOKMARK = {
    "id": ARTICLE_ID,
    "url": "https://example.org/reading",
    "title": "一篇用来检查阅读体验的示例文章",
    "description": "检查字号、行距、栏宽、归档和分类在 Mac 上的显示。",
    "site_name": "示例网站",
    "site": "example.org",
    "labels": ["设计", "mac-category/%E9%98%85%E8%AF%BB"],
    "read_progress": 0,
    "loaded": True,
    "state": 0,
    "is_marked": False,
    "is_archived": False,
    "has_article": True,
    "reading_time": 5,
    "created": "2026-10-24T08:00:00Z",
    "updated": "2026-10-24T08:00:00Z",
}
BOOKMARKS = {ARTICLE_ID: BOOKMARK}


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, value, headers=None, content_type="application/json"):
        data = value.encode() if isinstance(value, str) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, val in (headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") == "Bearer demo-token":
            return True
        self.reply(401, {"message": "Unauthorized"})
        return False

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/info":
            return self.reply(200, {"version": {"release": "0.23.5"}, "features": []})
        if not self.authorized():
            return
        if path == "/api/profile":
            return self.reply(200, {"user": {"username": "demo"}})
        if path == "/api/bookmarks/sync":
            return self.reply(200, [{"id": item["id"], "time": item["updated"], "type": "update"}
                                    for item in BOOKMARKS.values()])
        if path == "/api/bookmarks/collections":
            return self.reply(200, [])
        if path == "/api/bookmarks":
            return self.reply(200, list(BOOKMARKS.values()))
        if path.startswith("/api/bookmarks/") and path.endswith("/article"):
            body = "<h2>阅读是一种安静的练习</h2>" + "<p>这是一段用于检查排版的中文文字。保持自然的行距和足够的留白，让长篇文章读起来更舒服。</p>" * 12
            return self.reply(200, body, content_type="text/html; charset=utf-8")
        if path.startswith("/api/bookmarks/"):
            item = BOOKMARKS.get(path.rsplit("/", 1)[-1])
            return self.reply(200, item) if item else self.reply(404, {})
        self.reply(404, {})

    def do_PATCH(self):
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length", "0"))
        patch = json.loads(self.rfile.read(length) or b"{}")
        item_id = urlparse(self.path).path.rsplit("/", 1)[-1]
        item = BOOKMARKS.get(item_id)
        if not item:
            return self.reply(404, {})
        item.update(patch)
        self.reply(200, {"id": item_id, "updated": item["updated"]})

    def do_POST(self):
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        item_id = secrets.token_urlsafe(16)[:20]
        now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        BOOKMARKS[item_id] = {
            "id": item_id, "url": payload["url"], "title": payload.get("title") or payload["url"],
            "site_name": urlparse(payload["url"]).netloc, "labels": payload.get("labels", []),
            "read_progress": 0, "loaded": True, "state": 0, "is_marked": False,
            "is_archived": False, "has_article": True, "created": now, "updated": now,
        }
        self.reply(202, {"message": "accepted"}, headers={"Bookmark-Id": item_id})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 18979), Handler).serve_forever()
