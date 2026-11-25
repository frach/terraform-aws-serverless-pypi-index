"""Upstream proxy and cooldown. With the fake upstream the upload times are known, so every rule is checked
exactly; the real pypi.org is covered by a smoke test that only needs `requests` and `six` to exist.
"""

import hashlib
import re

import pytest
from conftest import publish, wait_until, write_wheel

FAKE_MARKER = 'name="fake-upstream"'  # only on pages the fake upstream renders itself


def page(http, cfg, project, **kwargs):
    resp = http.get(f"{cfg.index_url}{project}/", timeout=30, **kwargs)
    return resp.status_code, resp.text


def test_recent_release_is_hidden(http, fake):
    status, html = page(http, fake, "cw-fake-cooldown")
    assert status == 200
    assert "cw_fake_cooldown-1.0.0-py3-none-any.whl" in html
    assert "cw_fake_cooldown-2.0.0" not in html
    assert (
        FAKE_MARKER not in html
    ), "page should be rebuilt by the cooldown, not proxied"


def test_cooldown_boundary(http, fake):
    _, html = page(http, fake, "cw-fake-boundary")
    assert (
        "cw_fake_boundary-1.0.0" in html
    ), "a file older than the cooldown must be visible"
    assert (
        "cw_fake_boundary-1.1.0" not in html
    ), "a file younger than the cooldown must be hidden"


def test_project_with_only_fresh_files_has_no_links(http, fake):
    status, html = page(http, fake, "cw-fake-all-fresh")
    assert status == 200
    assert "<a " not in html


def test_file_without_upload_time_is_dropped(http, fake):
    _, html = page(http, fake, "cw-fake-no-time")
    assert "cw_fake_no_time-1.0.0" not in html


def test_excluded_project_is_proxied_with_fresh_files(http, fake):
    _, html = page(http, fake, "cw-fake-excluded")
    assert FAKE_MARKER in html
    assert "cw_fake_excluded-2.0.0" in html


def test_yanked_and_requires_python_are_kept(http, fake):
    _, html = page(http, fake, "cw-fake-yanked")
    assert re.search(
        r'cw_fake_yanked-1\.1\.0[^"]*"[^>]*data-yanked="broken release"', html
    )
    assert 'data-requires-python="&gt;=3.8"' in html


def test_hashes_match_the_files(http, fake):
    _, html = page(http, fake, "cw-fake-cooldown")
    href = (
        re.search(r'href="([^"]+cw_fake_cooldown-1\.0\.0[^"]+)"', html)
        .group(1)
        .replace("&amp;", "&")
    )
    url, digest = href.split("#sha256=")
    assert hashlib.sha256(http.get(url, timeout=30).content).hexdigest() == digest


def test_name_is_normalized_before_the_cooldown(http, fake):
    _, html = page(http, fake, "CW_Fake.Cooldown")
    assert "cw_fake_cooldown-1.0.0" in html and "cw_fake_cooldown-2.0.0" not in html


def test_big_project_is_served_gzipped(http, fake):
    # Over 1 MB as plain HTML, so it only fits the Lambda@Edge response limit compressed
    status, html = page(http, fake, "cw-fake-huge", headers={"Accept-Encoding": "gzip"})
    assert status == 200
    assert "cw_fake_huge-0.0.5999-py3-none-any.whl" in html


def test_upstream_error_is_a_502(http, fake):
    status, html = page(http, fake, "cw-fake-error")
    assert status == 502
    assert "fake" not in html.lower()


def test_private_package_shadows_upstream(cfg, http, fake, tmp_path):
    # Dependency confusion: a name that exists upstream and in the bucket only ever shows the private files
    wheel = write_wheel(tmp_path, "cw-fake-shadowed", "0.1.0")
    publish(cfg, wheel, "cw-fake-shadowed")

    def shadowed():
        _, html = page(http, cfg, "cw-fake-shadowed")
        return wheel.name in html and html

    html = wait_until(shadowed)
    assert html, "the private file never showed up"
    assert "cw_fake_shadowed-9.9.9" not in html


@pytest.mark.parametrize("project", ["requests"])
def test_real_pypi_page_is_built_by_the_cooldown(http, cfg, project):
    if not cfg.cooldown_days:
        pytest.skip("no cooldown in this deployment")
    status, html = page(http, cfg, project, headers={"Accept-Encoding": "gzip"})
    assert status == 200
    assert f"{project}-2" in html
    # pypi.org's own pages carry a pypi:repository-version meta tag; pages built by the cooldown don't
    assert "pypi:repository-version" not in html


def test_real_pypi_excluded_project_is_proxied(http, cfg):
    status, html = page(http, cfg, "six")
    assert status == 200
    assert "pypi:repository-version" in html
