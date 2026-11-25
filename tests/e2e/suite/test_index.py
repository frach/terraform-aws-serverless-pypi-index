"""PEP 503 pages for packages hosted in the bucket and file downloads from S3."""

import hashlib


def test_root_index_lists_the_package(http, cfg, published):
    assert f'href="{published.project}/"' in http.get(cfg.index_url, timeout=30).text


def test_package_page_links_the_file(http, cfg, published):
    page = http.get(f"{cfg.index_url}{published.project}/", timeout=30)
    assert page.status_code == 200
    assert page.headers["Content-Type"].startswith("text/html")
    assert f"/{published.filename}" in page.text


def test_package_page_normalizes_the_name(http, cfg, published):
    # PEP 503: E2E_Demo, e2e.demo and e2e-demo are the same project
    page = http.get(f"{cfg.index_url}E2E_Demo/", timeout=30)
    assert page.status_code == 200
    assert published.filename in page.text


def test_file_download_matches_the_upload(http, cfg, published):
    resp = http.get(
        f"{cfg.base_url}/{published.project}/{published.filename}", timeout=30
    )
    assert resp.status_code == 200
    assert (
        hashlib.sha256(resp.content).hexdigest()
        == hashlib.sha256(published.content).hexdigest()
    )


def test_unknown_package_is_404(http, cfg):
    # Not in the bucket and not upstream either
    assert (
        http.get(f"{cfg.index_url}cw-e2e-no-such-package-4f1c/", timeout=30).status_code
        == 404
    )


def test_missing_file_is_not_found(http, cfg, published):
    resp = http.get(f"{cfg.base_url}/{published.project}/no-such-file.whl", timeout=30)
    assert resp.status_code in (403, 404)
