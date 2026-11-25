"""Real clients against the index: what users actually run. Each test gets its own environment."""

import os
import sys

import pytest
from conftest import run


def venv(tmp_path):
    result = run("uv", "venv", "--seed", tmp_path / "venv")
    assert result.returncode == 0, result.stderr
    return (
        tmp_path / "venv" / ("Scripts" if sys.platform == "win32" else "bin") / "python"
    )


def installer(name, python, cfg):
    """Command prefix that installs into `python` from the private index."""
    if name == "pip":
        return [
            python,
            "-m",
            "pip",
            "install",
            "--no-cache-dir",
            "--index-url",
            cfg.pip_index,
        ]
    return [
        "uv",
        "pip",
        "install",
        "--no-cache",
        "--python",
        python,
        "--index-url",
        cfg.pip_index,
    ]


def installed_version(python, module):
    result = run(python, "-c", f"import {module}; print({module}.__version__)")
    return result.stdout.strip() if result.returncode == 0 else None


@pytest.mark.parametrize("client", ["pip", "uv"])
def test_install_private_package(client, cfg, published, tmp_path):
    python = venv(tmp_path)
    result = run(
        *installer(client, python, cfg), f"{published.project}=={published.version}"
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert installed_version(python, "e2e_demo") == published.version


@pytest.mark.parametrize("client", ["pip", "uv"])
def test_install_picks_the_release_outside_the_cooldown(client, fake, tmp_path):
    python = venv(tmp_path)
    result = run(*installer(client, python, fake), "cw-fake-cooldown")
    assert result.returncode == 0, result.stdout + result.stderr
    assert installed_version(python, "cw_fake_cooldown") == "1.0.0"


@pytest.mark.parametrize("client", ["pip", "uv"])
def test_pinning_a_release_in_cooldown_fails(client, fake, tmp_path):
    python = venv(tmp_path)
    result = run(*installer(client, python, fake), "cw-fake-cooldown==2.0.0")
    assert result.returncode != 0
    assert installed_version(python, "cw_fake_cooldown") is None


def test_excluded_project_installs_the_latest(fake, tmp_path):
    python = venv(tmp_path)
    result = run(*installer("pip", python, fake), "cw-fake-excluded")
    assert result.returncode == 0, result.stdout + result.stderr
    assert installed_version(python, "cw_fake_excluded") == "2.0.0"


@pytest.mark.parametrize("client", ["pip", "uv"])
def test_yanked_release_is_skipped(client, fake, tmp_path):
    python = venv(tmp_path)
    result = run(*installer(client, python, fake), "cw-fake-yanked")
    assert result.returncode == 0, result.stdout + result.stderr
    assert installed_version(python, "cw_fake_yanked") == "1.0.0"


def test_poetry_add_private_package(cfg, published, tmp_path):
    (tmp_path / "pyproject.toml").write_text(
        '[project]\nname = "consumer"\nversion = "0.0.0"\nrequires-python = ">=3.9"\n\n'
        "[tool.poetry]\npackage-mode = false\n\n"
        f'[[tool.poetry.source]]\nname = "e2e"\nurl = "{cfg.index_url}"\npriority = "primary"\n'
    )
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(tmp_path),
        "POETRY_VIRTUALENVS_IN_PROJECT": "true",
        "POETRY_HTTP_BASIC_E2E_USERNAME": cfg.user,
        "POETRY_HTTP_BASIC_E2E_PASSWORD": cfg.password,
    }
    result = run(
        sys.executable,
        "-m",
        "poetry",
        "add",
        "--no-interaction",
        "--source",
        "e2e",
        f"{published.project}=={published.version}",
        cwd=tmp_path,
        env=env,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        installed_version(tmp_path / ".venv" / "bin" / "python", "e2e_demo")
        == published.version
    )


def test_pip_download_through_the_real_pypi(cfg, tmp_path):
    python = venv(tmp_path)
    result = run(
        python,
        "-m",
        "pip",
        "download",
        "--no-cache-dir",
        "--no-deps",
        "-d",
        tmp_path / "dl",
        "--index-url",
        cfg.pip_index,
        "requests",
    )
    assert result.returncode == 0, result.stdout + result.stderr
