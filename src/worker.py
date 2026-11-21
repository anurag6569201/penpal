"""
Cloudflare Python Worker entrypoint for the Penpal brain (`penpal-brain`).

Deploys directly to Cloudflare Workers (`uv run pywrangler deploy`) using the
`python_workers` runtime, and can also be run locally as a standalone zero-Django
server on port 8000 (`python src/worker.py`).
"""

from __future__ import annotations

from pathlib import Path
import sys

# Ensure the repository root is on sys.path both in Pyodide and local execution.
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from chat.router import dispatch  # noqa: E402

try:
    from workers import Response, WorkerEntrypoint
except ImportError:
    class WorkerEntrypoint:  # type: ignore[no-redef]
        def __init__(self, env=None, ctx=None):
            self.env = env
            self.ctx = ctx

    class Response:  # type: ignore[no-redef]
        def __init__(self, body: str | bytes = "", status: int = 200,
                     headers: dict[str, str] | None = None):
            self.status = status
            self.headers = dict(headers or {})
            self.body = body.encode("utf-8") if isinstance(body, str) else body


class Default(WorkerEntrypoint):
    """Cloudflare Python Worker entrypoint (`main = "src/worker.py"`)."""

    async def fetch(self, request):
        method = str(getattr(request, "method", "GET"))
        url = str(getattr(request, "url", "/"))

        headers: dict[str, str] = {}
        req_headers = getattr(request, "headers", None)
        if req_headers is not None:
            if isinstance(req_headers, dict):
                headers = {str(k): str(v) for k, v in req_headers.items()}
            else:
                try:
                    for key, value in req_headers.entries():
                        headers[str(key)] = str(value)
                except Exception:  # noqa: BLE001
                    for name in (
                        "Authorization",
                        "Content-Type",
                        "X-Penpal-Token",
                        "X-Penpal-Device-Id",
                        "CF-Connecting-IP",
                        "X-Conversation-Id",
                    ):
                        val = req_headers.get(name)
                        if val:
                            headers[name] = str(val)

        body_text = ""
        if method.upper() not in ("GET", "HEAD", "OPTIONS"):
            body_text = await request.text()

        result = dispatch(
            method=method,
            url_or_path=url,
            headers=headers,
            body=body_text,
            env=getattr(self, "env", None),
        )
        return Response(
            result.body_text(),
            status=result.status,
            headers=result.merged_headers(),
        )


def run_local_server(host: str = "0.0.0.0", port: int = 8000) -> None:
    """Run the Penpal Worker router locally on port 8000 without Django."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import os

    try:
        from dotenv import load_dotenv
        load_dotenv(_ROOT / ".env")
    except ImportError:
        pass

    dev_mode = os.environ.get("PENPAL_DEV", "").lower() in ("1", "true", "yes")
    tokens = os.environ.get("PENPAL_TOKENS", "").strip()
    if not dev_mode and not tokens:
        raise RuntimeError(
            "Refusing to start without PENPAL_TOKENS (or PENPAL_DEV=1 for local dev)."
        )

    class WorkerHTTPRequestHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _handle(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length > 0 else b""
            hdrs = {k: v for k, v in self.headers.items()}
            result = dispatch(
                method=self.command,
                url_or_path=self.path,
                headers=hdrs,
                body=body,
            )
            body_bytes = result.body_text().encode("utf-8")
            self.send_response(result.status)
            for k, v in result.merged_headers().items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            if body_bytes:
                self.wfile.write(body_bytes)

        def do_GET(self) -> None:  # noqa: N802
            self._handle()

        def do_POST(self) -> None:  # noqa: N802
            self._handle()

        def do_OPTIONS(self) -> None:  # noqa: N802
            self._handle()

    server = ThreadingHTTPServer((host, port), WorkerHTTPRequestHandler)
    print(f"Penpal Python Worker listening on http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    run_local_server()
