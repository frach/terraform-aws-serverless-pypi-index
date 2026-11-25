"""Fake upstream index for the end-to-end test: pypi.org with a few made-up projects added.

Runs as a Lambda behind a function URL (tests/e2e/main.tf). The made-up projects (`cw-fake-*`) have files with
upload times relative to now, so the cooldown can be checked exactly instead of hoping that pypi.org has a
fresh release of something. Every other name is passed through to pypi.org, which keeps a smoke test against
the real upstream.

    GET /simple/<project>/   PEP 691 JSON (Accept: application/vnd.pypi.simple.v1+json) or PEP 503 HTML
    GET /files/<filename>    a tiny, valid wheel built on the fly (deterministic, so hashes are stable)
"""

import base64
import gzip
import hashlib
import io
import json
import os
import re
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from html import escape

PYPI_URL = os.environ.get("PYPI_URL", "https://pypi.org/simple")
COOLDOWN_DAYS = int(os.environ.get("COOLDOWN_DAYS", "7"))

JSON_TYPE = "application/vnd.pypi.simple.v1+json"
FAKE_MARKER = '<meta name="fake-upstream" content="1">'
HUGE_FILES = (
    6000  # enough for > 1 MB of plain HTML, so the cooldown page has to be gzipped
)
OLD = timedelta(days=30)
FRESH = timedelta(hours=1)


def project_files() -> dict:
    """Project name => list of (version, age or None, extra PEP 691 fields)."""
    cooldown = timedelta(days=COOLDOWN_DAYS)
    return {
        # Old release visible, new one hidden by the cooldown
        "cw-fake-cooldown": [("1.0.0", OLD, {}), ("2.0.0", FRESH, {})],
        # Just outside and just inside the cooldown window
        "cw-fake-boundary": [
            ("1.0.0", cooldown + timedelta(hours=1), {}),
            ("1.1.0", cooldown - timedelta(hours=1), {}),
        ],
        # Only a fresh release: the page is empty, nothing is installable
        "cw-fake-all-fresh": [("1.0.0", FRESH, {})],
        # Listed in upstream_cooldown_exclude: served straight from here, fresh release included
        "cw-fake-excluded": [("1.0.0", OLD, {}), ("2.0.0", FRESH, {})],
        # Yanked file (PEP 592) and requires-python (PEP 503) must survive the rebuilt page
        "cw-fake-yanked": [
            ("1.0.0", OLD, {"requires-python": ">=3.8"}),
            ("1.1.0", OLD, {"yanked": "broken release"}),
        ],
        # No upload time: the cooldown can't tell its age, so the file is dropped
        "cw-fake-no-time": [("1.0.0", None, {})],
        # Also published to the private index by the test: the private files must win
        "cw-fake-shadowed": [("9.9.9", OLD, {})],
        "cw-fake-huge": [(f"0.0.{i}", OLD, {}) for i in range(HUGE_FILES)],
    }


ERROR_PROJECT = "cw-fake-error"  # upstream fails with 500


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def wheel_name(project: str, version: str) -> str:
    return f"{project.replace('-', '_')}-{version}-py3-none-any.whl"


def _record_hash(data: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return f"sha256={digest.decode()}"


@lru_cache(maxsize=256)
def build_wheel(project: str, version: str) -> bytes:
    """A minimal pure-Python wheel with a module that knows its version."""
    module = project.replace("-", "_")
    dist_info = f"{module}-{version}.dist-info"
    files = {
        f"{module}/__init__.py": f'__version__ = "{version}"\n',
        f"{dist_info}/METADATA": f"Metadata-Version: 2.1\nName: {project}\nVersion: {version}\n",
        f"{dist_info}/WHEEL": "Wheel-Version: 1.0\nGenerator: fake-upstream\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    }
    record = "".join(
        f"{path},{_record_hash(content.encode())},{len(content.encode())}\n"
        for path, content in files.items()
    )
    files[f"{dist_info}/RECORD"] = record + f"{dist_info}/RECORD,,\n"

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for path, content in files.items():
            zf.writestr(zipfile.ZipInfo(path, (1980, 1, 1, 0, 0, 0)), content)
    return buf.getvalue()


def file_entry(
    base_url: str, project: str, version: str, age, extra: dict, now
) -> dict:
    filename = wheel_name(project, version)
    if project == "cw-fake-huge":
        # Never downloaded; hashing thousands of real wheels would make the page too slow
        sha256 = hashlib.sha256(filename.encode()).hexdigest()
    else:
        sha256 = hashlib.sha256(build_wheel(project, version)).hexdigest()
    entry = {
        "filename": filename,
        "url": f"{base_url}/files/{filename}",
        "hashes": {"sha256": sha256},
    }
    if age is not None:
        entry["upload-time"] = (now - age).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    entry.update(extra)
    return entry


def project_json(base_url: str, project: str, now) -> dict:
    files = [
        file_entry(base_url, project, version, age, extra, now)
        for version, age, extra in project_files()[project]
    ]
    return {
        "meta": {"api-version": "1.1"},
        "name": project,
        "files": files,
        "versions": sorted({v for v, _, _ in project_files()[project]}),
    }


def project_html(data: dict) -> str:
    links = ""
    for f in data["files"]:
        attrs = f' href="{escape(f["url"])}#sha256={f["hashes"]["sha256"]}"'
        if f.get("requires-python"):
            attrs += f' data-requires-python="{escape(f["requires-python"])}"'
        if f.get("yanked"):
            attrs += f' data-yanked="{escape(f["yanked"])}"'
        links += f'    <a{attrs}>{escape(f["filename"])}</a><br/>\n'
    return (
        f"<!DOCTYPE html>\n<html>\n  <head>\n    {FAKE_MARKER}\n"
        f"    <title>Links for {escape(data['name'])}</title>\n  </head>\n"
        f"  <body>\n{links}  </body>\n</html>"
    )


def respond(status: int, body, content_type: str, accept_encoding: str = "") -> dict:
    if isinstance(body, str):
        body = body.encode()
    headers = {"Content-Type": content_type}
    if "gzip" in accept_encoding and len(body) > 10_000:
        body = gzip.compress(body)
        headers["Content-Encoding"] = "gzip"
    return {
        "statusCode": status,
        "headers": headers,
        "body": base64.b64encode(body).decode(),
        "isBase64Encoded": True,
    }


def proxy_to_pypi(project: str, accept: str) -> dict:
    req = urllib.request.Request(
        f"{PYPI_URL.rstrip('/')}/{project}/",
        headers={"Accept": accept or "text/html", "User-Agent": "fake-upstream"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return respond(
                resp.status, resp.read(), resp.headers.get("Content-Type", "text/html")
            )
    except urllib.error.HTTPError as e:
        return respond(e.code, e.read(), e.headers.get("Content-Type", "text/plain"))


def handle(method: str, path: str, headers: dict, base_url: str, now=None) -> dict:
    now = now or datetime.now(timezone.utc)
    if method != "GET":
        return respond(405, "Method Not Allowed", "text/plain")

    parts = [p for p in path.split("/") if p]
    accept = headers.get("accept", "")
    accept_encoding = headers.get("accept-encoding", "")

    if len(parts) == 2 and parts[0] == "simple":
        project = normalize(parts[1])
        if project == ERROR_PROJECT:
            return respond(500, "Internal Server Error", "text/plain")
        if project not in project_files():
            return proxy_to_pypi(project, accept)
        data = project_json(base_url, project, now)
        if JSON_TYPE in accept:
            return respond(200, json.dumps(data), JSON_TYPE, accept_encoding)
        return respond(200, project_html(data), "text/html", accept_encoding)

    if len(parts) == 2 and parts[0] == "files":
        match = re.fullmatch(r"(cw_fake_[a-z_]+)-([0-9.]+)-py3-none-any\.whl", parts[1])
        project = match and match.group(1).replace("_", "-")
        if project in project_files() and any(
            v == match.group(2) for v, _, _ in project_files()[project]
        ):
            return respond(
                200, build_wheel(project, match.group(2)), "application/octet-stream"
            )

    return respond(404, "Not Found", "text/plain")


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    ctx = event.get("requestContext", {})
    return handle(
        ctx.get("http", {}).get("method", "GET"),
        event.get("rawPath", "/"),
        headers,
        f"https://{ctx.get('domainName', headers.get('host', ''))}",
    )
