"""Read authentication (viewer-request Lambda@Edge) and the response headers CloudFront adds."""

import requests


def test_index_without_credentials_is_rejected(cfg):
    resp = requests.get(cfg.index_url, timeout=30)
    assert resp.status_code == 401
    assert resp.headers.get("WWW-Authenticate", "").startswith("Basic ")


def test_index_with_wrong_password_is_rejected(cfg):
    resp = requests.get(cfg.index_url, auth=(cfg.user, "wrong"), timeout=30)
    assert resp.status_code == 401


def test_unknown_user_is_rejected(cfg):
    resp = requests.get(cfg.index_url, auth=("nobody", cfg.password), timeout=30)
    assert resp.status_code == 401


def test_upload_password_does_not_grant_read_access(upload_cfg):
    resp = requests.get(
        upload_cfg.index_url,
        auth=(upload_cfg.user, upload_cfg.upload_password),
        timeout=30,
    )
    assert resp.status_code == 401


def test_index_with_valid_credentials(http, cfg):
    assert http.get(cfg.index_url, timeout=30).status_code == 200


def test_package_file_without_credentials_is_rejected(cfg, published):
    resp = requests.get(
        f"{cfg.base_url}/{published.project}/{published.filename}", timeout=30
    )
    assert resp.status_code == 401


def test_upstream_page_without_credentials_is_rejected(cfg):
    assert requests.get(f"{cfg.index_url}requests/", timeout=30).status_code == 401


def test_security_headers(http, cfg):
    headers = http.get(cfg.index_url, timeout=30).headers
    assert "max-age=" in headers.get("Strict-Transport-Security", "")
    assert headers.get("X-Content-Type-Options") == "nosniff"
    assert "X-Frame-Options" in headers


def test_plain_http_is_not_served(cfg):
    resp = requests.get(
        cfg.index_url.replace("https://", "http://", 1),
        allow_redirects=False,
        timeout=30,
    )
    assert resp.status_code in (301, 302, 307, 308, 403)
