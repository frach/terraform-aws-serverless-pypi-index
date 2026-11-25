"""Uploads through <index host>/upload/: separate credentials, no overwriting, validation, all three clients."""

import os
import sys

import requests
from conftest import package_lists, run, upload, wait_until, write_wheel


def test_upload_without_credentials_is_rejected(upload_cfg, published):
    resp = requests.post(
        upload_cfg.upload_url, data={":action": "file_upload"}, timeout=30
    )
    assert resp.status_code == 401


def test_read_password_is_rejected_for_uploads(upload_cfg, published):
    resp = upload(
        upload_cfg,
        published.project,
        published.filename,
        published.content,
        upload_cfg.password,
    )
    assert resp.status_code == 401


def test_get_is_not_allowed(upload_cfg):
    resp = requests.get(
        upload_cfg.upload_url,
        auth=(upload_cfg.user, upload_cfg.upload_password),
        timeout=30,
    )
    assert resp.status_code == 405


def test_identical_reupload_succeeds(upload_cfg, published):
    resp = upload(upload_cfg, published.project, published.filename, published.content)
    assert resp.status_code == 200


def test_overwriting_with_different_content_is_refused(upload_cfg, http, published):
    resp = upload(
        upload_cfg, published.project, published.filename, b"different content"
    )
    assert resp.status_code == 409
    # The original file is untouched
    download = http.get(
        f"{upload_cfg.base_url}/{published.project}/{published.filename}", timeout=30
    )
    assert download.content == published.content


def test_file_of_another_project_is_rejected(upload_cfg, published):
    resp = upload(
        upload_cfg, "some-other-project", published.filename, published.content
    )
    assert resp.status_code == 400


def test_invalid_file_name_is_rejected(upload_cfg, published):
    resp = upload(
        upload_cfg,
        published.project,
        "../e2e_demo-1.0-py3-none-any.whl",
        published.content,
    )
    assert resp.status_code == 400


def test_uv_publish(upload_cfg, http, published, tmp_path):
    wheel = write_wheel(tmp_path, published.project, f"{published.version}.1")
    result = run(
        "uv",
        "publish",
        "--publish-url",
        upload_cfg.upload_url,
        "--username",
        upload_cfg.user,
        "--password",
        upload_cfg.upload_password,
        wheel,
    )
    assert (
        result.returncode == 0
    ), f"uv publish failed:\n{result.stdout}\n{result.stderr}"
    assert wait_until(
        lambda: package_lists(http, upload_cfg, published.project, wheel.name)
    )


def test_poetry_publish(upload_cfg, http, published, tmp_path):
    version = f"{published.version}.2"
    (tmp_path / "pyproject.toml").write_text(
        f'[project]\nname = "{published.project}"\nversion = "{version}"\n'
    )
    (tmp_path / "dist").mkdir()
    wheel = write_wheel(tmp_path / "dist", published.project, version)
    env = {
        "POETRY_REPOSITORIES_E2E_URL": upload_cfg.upload_url,
        "PATH": os.environ["PATH"],
        "HOME": str(tmp_path),
    }
    result = run(
        sys.executable,
        "-m",
        "poetry",
        "publish",
        "-r",
        "e2e",
        "--no-interaction",
        "-u",
        upload_cfg.user,
        "-p",
        upload_cfg.upload_password,
        cwd=tmp_path,
        env=env,
    )
    assert (
        result.returncode == 0
    ), f"poetry publish failed:\n{result.stdout}\n{result.stderr}"
    assert wait_until(
        lambda: package_lists(http, upload_cfg, published.project, wheel.name)
    )
