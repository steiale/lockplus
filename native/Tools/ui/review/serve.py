#!/usr/bin/env python3
"""Local review server (stdlib only, 127.0.0.1 only). Serves the package directory and accepts POST /comments.

Comments are written atomically to docs/native/ux-review/comments.json (+ a COMMENTS.md mirror) in the repo.
Usage: python3 -I serve.py <package-dir> [port]   (default port 8765, falls back upward if busy)
"""
import http.server, json, os, re, socketserver, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]                                   # native/Tools/ui/review -> repo root
OUT = REPO / "docs" / "native" / "ux-review"
COMMENTS, MIRROR = OUT / "comments.json", OUT / "COMMENTS.md"
ID_RE = re.compile(r"^S-\d{1,2}\.\d{2}(-[a-z])?$")
STATUSES = {"open", "done", "wontdo"}
MAX_BODY, MAX_TEXT = 512 * 1024, 20000
MANIFEST = json.loads((HERE / "screens.json").read_text())
TITLES = {s["id"]: s["title"] for s in MANIFEST["screens"]}


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def load():
    try:
        d = json.loads(COMMENTS.read_text())
        if isinstance(d, dict):
            return d
    except (OSError, ValueError):
        pass
    return {"general": {"text": "", "status": "open", "updated": ""}, "comments": {}}


def validate(doc):
    """Returns a cleaned document or raises ValueError. Only known keys survive."""
    if not isinstance(doc, dict) or set(doc) - {"general", "comments"}:
        raise ValueError("shape")
    def entry(e):
        if not isinstance(e, dict) or set(e) - {"text", "status", "updated"}:
            raise ValueError("entry")
        text, status = e.get("text", ""), e.get("status", "open")
        if not isinstance(text, str) or len(text) > MAX_TEXT or status not in STATUSES:
            raise ValueError("entry value")
        return {"text": text, "status": status}
    out = {"general": entry(doc.get("general", {})), "comments": {}}
    comments = doc.get("comments", {})
    if not isinstance(comments, dict) or len(comments) > 2000:
        raise ValueError("comments")
    for k, v in comments.items():
        if not isinstance(k, str) or not ID_RE.match(k):
            raise ValueError("id")
        e = entry(v)
        if e["text"].strip():
            out["comments"][k] = e
    return out


def merge_timestamps(new, old):
    t = now()
    def stamp(n, o):
        same = o and o.get("text") == n["text"] and o.get("status") == n["status"]
        n["updated"] = o["updated"] if same and o.get("updated") else t
    stamp(new["general"], old.get("general"))
    for k, n in new["comments"].items():
        stamp(n, old.get("comments", {}).get(k))
    return new


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def markdown(doc):
    label = {"open": "open", "done": "done", "wontdo": "won't do"}
    lines = ["# UI review comments", "", "Written by `native/Tools/ui/review/serve.py`; edit status in the review page. Screen IDs: see `screens.json`.", ""]
    g = doc.get("general", {})
    if g.get("text", "").strip():
        lines += ["## General [%s]" % label[g["status"]], "", g["text"].strip(), "", "_%s_" % g.get("updated", ""), ""]
    def key(k):
        m = re.match(r"S-(\d+)\.(\d+)(?:-([a-z]))?", k); return (int(m[1]), int(m[2]), m[3] or "")
    known = [k for k in sorted(doc["comments"], key=key) if k.split("-")[0:2] and re.sub(r"-[a-z]$", "", k) in TITLES]
    orphans = [k for k in sorted(doc["comments"], key=key) if k not in known]
    for k in known:
        c = doc["comments"][k]
        lines += ["## %s: %s [%s]" % (k, TITLES[re.sub(r"-[a-z]$", "", k)], label[c["status"]]), "", c["text"].strip(), "", "_%s_" % c.get("updated", ""), ""]
    if orphans:
        lines += ["## Orphaned (screen no longer in the manifest)", ""]
        for k in orphans:
            c = doc["comments"][k]
            lines += ["### %s [%s]" % (k, label[c["status"]]), "", c["text"].strip(), "", "_%s_" % c.get("updated", ""), ""]
    return "\n".join(lines)


class Handler(http.server.SimpleHTTPRequestHandler):
    root = "."

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=Handler.root, **kw)

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if "?" in self.path or "#" in self.path or ".." in self.path:
            return self._send(404)
        if self.path == "/comments":
            return self._send(200, json.dumps(load()).encode(), "application/json")
        super().do_GET()

    def list_directory(self, path):
        return self._send(404)

    def do_HEAD(self):
        self._send(405)

    def do_POST(self):
        if self.path != "/comments":
            return self._send(404)
        origin = self.headers.get("Origin", "")
        if origin and origin not in (f"http://127.0.0.1:{self.server.server_port}", f"http://localhost:{self.server.server_port}"):
            return self._send(403, b"origin")
        if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
            return self._send(415)
        try:
            n = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._send(411)
        if n <= 0 or n > MAX_BODY:
            return self._send(413)
        try:
            doc = merge_timestamps(validate(json.loads(self.rfile.read(n))), load())
        except ValueError:
            return self._send(400, b"invalid")
        atomic_write(COMMENTS, json.dumps(doc, indent=1, ensure_ascii=False) + "\n")
        atomic_write(MIRROR, markdown(doc) + "\n")
        self._send(200, json.dumps(doc).encode(), "application/json")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = False


def main():
    Handler.root = str(Path(sys.argv[1]).resolve())
    start = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
    for port in range(start, start + 10):
        try:
            srv = Server(("127.0.0.1", port), Handler)
            break
        except OSError:
            continue
    else:
        sys.exit("no free port")
    print("http://127.0.0.1:%d/" % port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
