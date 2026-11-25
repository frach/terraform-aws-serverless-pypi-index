"""End-to-end suite for a deployed index. Configured only through environment variables, so it runs against any
deployment: this module (scripts/e2e.sh), the coldwheel-dev/pypi wrapper or Coldwheel Pro.

    E2E_INDEX_URL          https://<host>/simple/ (required)
    E2E_USER, E2E_PASSWORD read credentials (required)
    E2E_UPLOAD_URL         upload endpoint; without it upload tests are skipped and the test package goes through S3
    E2E_UPLOAD_PASSWORD    upload password for E2E_USER
    E2E_S3_BUCKET          bucket for publishing without E2E_UPLOAD_URL (needs the aws CLI)
    E2E_DISTRIBUTION_ID    CloudFront distribution to invalidate after an S3 publish
    E2E_FAKE_UPSTREAM      1 when upstream_index_url points at tests/e2e/fake_upstream (enables exact cooldown tests)
    E2E_COOLDOWN_DAYS      upstream_cooldown_days of the deployment (0 = no cooldown)
"""

import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import pytest
import requests

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "fake_upstream"))
from fake_upstream import build_wheel, wheel_name  # noqa: E402

PKG_NAME = "e2e-demo"


@dataclass(frozen=True)
class Config:
    index_url: str
    user: str
    password: str
    upload_url: Optional[str]
    upload_password: Optional[str]
    s3_bucket: Optional[str]
    distribution_id: Optional[str]
    fake_upstream: bool
    cooldown_days: int

    @property
    def base_url(self) -> str:
        return self.index_url.split("/simple/")[0]

    @property
    def auth(self) -> tuple:
        return (self.user, self.password)

    @property
    def pip_index(self) -> str:
        scheme, rest = self.index_url.split("://", 1)
        return f"{scheme}://{self.user}:{self.password}@{rest}"


@pytest.fixture(scope="session")
def cfg() -> Config:
    missing = [
        v
        for v in ("E2E_INDEX_URL", "E2E_USER", "E2E_PASSWORD")
        if not os.environ.get(v)
    ]
    if missing:
        pytest.exit(
            f"missing environment variables: {', '.join(missing)}", returncode=2
        )
    index_url = os.environ["E2E_INDEX_URL"].rstrip("/") + "/"
    return Config(
        index_url=index_url,
        user=os.environ["E2E_USER"],
        password=os.environ["E2E_PASSWORD"],
        upload_url=os.environ.get("E2E_UPLOAD_URL") or None,
        upload_password=os.environ.get("E2E_UPLOAD_PASSWORD") or None,
        s3_bucket=os.environ.get("E2E_S3_BUCKET") or None,
        distribution_id=os.environ.get("E2E_DISTRIBUTION_ID") or None,
        fake_upstream=os.environ.get("E2E_FAKE_UPSTREAM") == "1",
        cooldown_days=int(os.environ.get("E2E_COOLDOWN_DAYS", "0")),
    )


@pytest.fixture(scope="session")
def http(cfg) -> requests.Session:
    """Authenticated session for reading the index."""
    session = requests.Session()
    session.auth = cfg.auth
    return session


@pytest.fixture
def upload_cfg(cfg) -> Config:
    if not cfg.upload_url:
        pytest.skip("no E2E_UPLOAD_URL: uploads aren't enabled in this deployment")
    return cfg


@pytest.fixture
def fake(cfg) -> Config:
    if not cfg.fake_upstream:
        pytest.skip("needs the fake upstream (E2E_FAKE_UPSTREAM=1)")
    if not 1 <= cfg.cooldown_days < 29:
        pytest.skip("fake upstream projects assume a cooldown of 1-28 days")
    return cfg


def wait_until(check, timeout: float = 90, interval: float = 3):
    """Retry check() until it returns a truthy value. CloudFront invalidations take a few seconds to a minute."""
    deadline = time.monotonic() + timeout
    while True:
        result = check()
        if result or time.monotonic() > deadline:
            return result
        time.sleep(interval)


def run(*cmd, **kwargs) -> subprocess.CompletedProcess:
    """Run a client command; on failure the output ends up in the assertion message."""
    kwargs.setdefault("env", {**os.environ, "PIP_DISABLE_PIP_VERSION_CHECK": "1"})
    return subprocess.run(
        [str(c) for c in cmd], capture_output=True, text=True, timeout=600, **kwargs
    )


def upload(
    cfg: Config,
    project: str,
    filename: str,
    content: bytes,
    password: Optional[str] = None,
):
    """Legacy upload API call, the way twine sends it."""
    return requests.post(
        cfg.upload_url,
        auth=(cfg.user, password if password is not None else cfg.upload_password),
        data={":action": "file_upload", "protocol_version": "1", "name": project},
        files={"content": (filename, content, "application/octet-stream")},
        timeout=30,
    )


def write_wheel(directory: Path, project: str, version: str) -> Path:
    path = directory / wheel_name(project, version)
    path.write_bytes(build_wheel(project, version))
    return path


def package_lists(http, cfg: Config, project: str, filename: str) -> bool:
    resp = http.get(f"{cfg.index_url}{project}/", timeout=30)
    return resp.status_code == 200 and filename in resp.text


def publish(cfg: Config, wheel: Path, project: str):
    """Publish with twine when uploads are enabled, otherwise straight to S3 and invalidate the index."""
    if cfg.upload_url:
        result = run(
            sys.executable,
            "-m",
            "twine",
            "upload",
            "--non-interactive",
            "--repository-url",
            cfg.upload_url,
            "-u",
            cfg.user,
            "-p",
            cfg.upload_password,
            wheel,
        )
        assert (
            result.returncode == 0
        ), f"twine upload failed:\n{result.stdout}\n{result.stderr}"
    elif cfg.s3_bucket:
        result = run("aws", "s3", "cp", wheel, f"s3://{cfg.s3_bucket}/{project}/")
        assert result.returncode == 0, result.stderr
        if cfg.distribution_id:
            run(
                "aws",
                "cloudfront",
                "create-invalidation",
                "--distribution-id",
                cfg.distribution_id,
                "--paths",
                "/simple/*",
            )
    else:
        pytest.skip("can't publish: set E2E_UPLOAD_URL or E2E_S3_BUCKET")


@dataclass(frozen=True)
class Published:
    project: str
    version: str
    filename: str
    content: bytes


@pytest.fixture(scope="session")
def published(cfg, http, tmp_path_factory) -> Published:
    """The test package, published once per session with a version that is new on every run."""
    version = f"0.0.{int(time.time())}"
    wheel = write_wheel(tmp_path_factory.mktemp("published"), PKG_NAME, version)
    publish(cfg, wheel, PKG_NAME)
    assert wait_until(
        lambda: package_lists(http, cfg, PKG_NAME, wheel.name)
    ), f"{wheel.name} didn't show up on the index"
    return Published(PKG_NAME, version, wheel.name, wheel.read_bytes())
