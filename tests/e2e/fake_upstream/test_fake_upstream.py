import base64
import gzip
import hashlib
import io
import json
import zipfile
from datetime import datetime, timezone

import fake_upstream as fu

NOW = datetime(2026, 1, 31, 12, tzinfo=timezone.utc)
BASE = "https://fake.example"


def get(path, accept="", encoding=""):
    resp = fu.handle(
        "GET", path, {"accept": accept, "accept-encoding": encoding}, BASE, NOW
    )
    body = base64.b64decode(resp["body"])
    if resp["headers"].get("Content-Encoding") == "gzip":
        body = gzip.decompress(body)
    return resp["statusCode"], resp["headers"]["Content-Type"], body


def test_json_page_has_upload_times_and_hashes():
    status, ctype, body = get("/simple/cw-fake-cooldown/", fu.JSON_TYPE)
    data = json.loads(body)
    assert status == 200 and ctype == fu.JSON_TYPE
    times = {f["filename"]: f["upload-time"] for f in data["files"]}
    assert (
        times["cw_fake_cooldown-1.0.0-py3-none-any.whl"]
        == "2026-01-01T12:00:00.000000Z"
    )
    assert (
        times["cw_fake_cooldown-2.0.0-py3-none-any.whl"]
        == "2026-01-31T11:00:00.000000Z"
    )


def test_hash_matches_the_served_wheel():
    _, _, body = get("/simple/cw-fake-cooldown/", fu.JSON_TYPE)
    entry = json.loads(body)["files"][0]
    assert entry["url"] == f"{BASE}/files/{entry['filename']}"
    status, _, wheel = get(f"/files/{entry['filename']}")
    assert status == 200
    assert hashlib.sha256(wheel).hexdigest() == entry["hashes"]["sha256"]
    names = zipfile.ZipFile(io.BytesIO(wheel)).namelist()
    assert "cw_fake_cooldown/__init__.py" in names
    assert "cw_fake_cooldown-1.0.0.dist-info/RECORD" in names


def test_wheels_are_deterministic():
    fu.build_wheel.cache_clear()
    first = fu.build_wheel("cw-fake-cooldown", "1.0.0")
    fu.build_wheel.cache_clear()
    assert fu.build_wheel("cw-fake-cooldown", "1.0.0") == first


def test_html_page_is_marked_and_keeps_attributes():
    status, ctype, body = get("/simple/cw-fake-yanked/", "text/html")
    html = body.decode()
    assert status == 200 and ctype == "text/html"
    assert fu.FAKE_MARKER in html
    assert 'data-yanked="broken release"' in html
    assert 'data-requires-python="&gt;=3.8"' in html


def test_big_project_is_gzipped_when_asked():
    resp = fu.handle(
        "GET",
        "/simple/cw-fake-huge/",
        {"accept": fu.JSON_TYPE, "accept-encoding": "gzip"},
        BASE,
        NOW,
    )
    assert resp["headers"]["Content-Encoding"] == "gzip"
    assert (
        len(json.loads(gzip.decompress(base64.b64decode(resp["body"])))["files"])
        == fu.HUGE_FILES
    )


def test_names_are_normalized_and_errors_simulated():
    assert get("/simple/CW_Fake.Cooldown/", fu.JSON_TYPE)[0] == 200
    assert get("/simple/cw-fake-error/")[0] == 500
    assert get("/files/cw_fake_cooldown-3.0.0-py3-none-any.whl")[0] == 404
    assert get("/files/../etc/passwd")[0] == 404
    assert fu.handle("POST", "/simple/x/", {}, BASE, NOW)["statusCode"] == 405


def test_unknown_projects_go_to_pypi(monkeypatch):
    calls = []
    monkeypatch.setattr(
        fu,
        "proxy_to_pypi",
        lambda project, accept: calls.append((project, accept)) or "proxied",
    )
    assert (
        fu.handle("GET", "/simple/Requests/", {"accept": fu.JSON_TYPE}, BASE, NOW)
        == "proxied"
    )
    assert calls == [("requests", fu.JSON_TYPE)]


def test_no_time_file_has_no_upload_time():
    _, _, body = get("/simple/cw-fake-no-time/", fu.JSON_TYPE)
    assert "upload-time" not in json.loads(body)["files"][0]
