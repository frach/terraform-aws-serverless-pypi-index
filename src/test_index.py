import sys
import os
import base64
import pytest
from unittest.mock import patch, MagicMock

# Ensure the current directory (src) is at the top of the execution path
sys.path.insert(0, os.path.dirname(__file__))

# Prevent boto3 from failing during initial module compilation when raw strings exist
with patch("boto3.client") as mock_boto:
    import index
    from index import handler

# Mock structural data updated to match your actual flat S3 bucket layout
MOCK_S3_CONTENTS = [
    {"Key": "six/six-1.17.0-py2.py3-none-any.whl"},
    {"Key": "requests/requests-2.28.1-py3-none-any.whl"},
    {"Key": "requests/requests-2.28.0.tar.gz"},
    {"Key": "Flask_SQLAlchemy/Flask_SQLAlchemy-3.0.2-py3-none-any.whl"},
    {"Key": "some-other-pkg/some_other_pkg-1.0.0.whl"},
    {"Key": "root_level_ignored.txt"},  # Files at root with no folder split are skipped
]


def create_cloudfront_event(
    uri: str, event_type: str = "origin-request", headers: dict = None
):
    """Helper utility to generate standard Lambda@Edge payload structure."""
    return {
        "Records": [
            {
                "cf": {
                    "config": {"eventType": event_type},
                    "request": {
                        "uri": uri,
                        "querystring": "",
                        "method": "GET",
                        "clientIp": "1.2.3.4",
                        "headers": headers or {},
                    },
                }
            }
        ]
    }


def basic_auth_headers(username: str, password: str) -> dict:
    token = base64.b64encode(f"{username}:{password}".encode()).decode()
    return {"authorization": [{"key": "Authorization", "value": f"Basic {token}"}]}


def mock_listing(mock_s3, contents=MOCK_S3_CONTENTS):
    """Make the mocked S3 paginator yield the given objects as a single page."""
    mock_s3.get_paginator.return_value.paginate.return_value = [{"Contents": contents}]


@pytest.fixture(autouse=True)
def setup_test_environment():
    """Dynamically set default configurations for testing execution."""
    index.BUCKET_NAME = "terraform-b31a35574fb1b63ac4e6cf477f"
    index.DATA_LAYER_REGION = "us-east-1"
    index.AUTH_ENABLED = False
    index.AUTH_SECRET_ID = "serverless-pypi-index-credentials"
    index.UPSTREAM_ENABLED = False
    index.UPSTREAM_INDEX_URL = "https://pypi.org/simple"
    index._credentials_cache.update({"value": None, "expires_at": 0.0})
    yield


@patch("index.s3_client")
def test_lambda_returns_root_simple_index(mock_s3, setup_test_environment):
    """Verify that /simple/ returns a valid, normalized root directory list of packages."""
    mock_listing(mock_s3)

    event = create_cloudfront_event("/simple/")
    response = handler(event, None)

    assert response["status"] == "200"
    # FIXED: Aligned with your exact list array element evaluation syntax [0]
    assert "text/html" in response["headers"]["content-type"][0]["value"]

    body = response["body"]
    assert '<a href="six/">six</a>' in body
    assert '<a href="requests/">requests</a>' in body
    assert '<a href="flask-sqlalchemy/">flask-sqlalchemy</a>' in body
    assert '<a href="some-other-pkg/">some-other-pkg</a>' in body
    assert "root_level_ignored" not in body


@patch("index.s3_client")
def test_lambda_returns_package_files(mock_s3, setup_test_environment):
    """Verify that /simple/<package>/ maps to accurate files grouped under that project."""
    mock_listing(mock_s3)

    event = create_cloudfront_event("/simple/six")
    response = handler(event, None)

    assert response["status"] == "200"
    # FIXED: Aligned with your list array element evaluation syntax [0]
    assert "text/html" in response["headers"]["content-type"][0]["value"]

    body = response["body"]
    assert "Links for six" in body
    assert (
        '<a href="/six/six-1.17.0-py2.py3-none-any.whl">six-1.17.0-py2.py3-none-any.whl</a>'
        in body
    )
    assert "Flask_SQLAlchemy" not in body


@patch("index.s3_client")
def test_lambda_handles_package_normalization_in_routing(
    mock_s3, setup_test_environment
):
    """Verify routing correctly applies PEP 503 translation rules on misaligned input targets."""
    mock_listing(mock_s3)

    event = create_cloudfront_event("/simple/flask-sqlalchemy")
    response = handler(event, None)

    assert response["status"] == "200"
    body = response["body"]
    assert (
        '<a href="/Flask_SQLAlchemy/Flask_SQLAlchemy-3.0.2-py3-none-any.whl">' in body
    )


@patch("index.s3_client")
def test_lambda_passthrough_for_other_urls(mock_s3, setup_test_environment):
    """Verify paths unrelated to /simple yield standard request objects for native handling."""
    mock_listing(mock_s3)

    event = create_cloudfront_event("/six/six-1.17.0-py2.py3-none-any.whl")
    response = handler(event, None)

    assert "uri" in response
    assert response["uri"] == "/six/six-1.17.0-py2.py3-none-any.whl"


@patch("index.s3_client")
def test_lambda_returns_404_for_unknown_package_without_upstream(
    mock_s3, setup_test_environment
):
    """Verify a package missing from S3 yields 404 when the upstream proxy is disabled."""
    mock_listing(mock_s3)

    response = handler(create_cloudfront_event("/simple/numpy/"), None)

    assert response["status"] == "404"


@patch("index.s3_client")
def test_lambda_routes_unknown_package_to_upstream(mock_s3, setup_test_environment):
    """Verify a package missing from S3 is re-targeted to the upstream index origin."""
    index.UPSTREAM_ENABLED = True
    mock_listing(mock_s3)

    event = create_cloudfront_event(
        "/simple/NumPy", headers=basic_auth_headers("alice", "secret")
    )
    response = handler(event, None)

    assert response["uri"] == "/simple/numpy/"
    assert response["origin"]["custom"]["domainName"] == "pypi.org"
    assert response["origin"]["custom"]["protocol"] == "https"
    assert response["headers"]["host"][0]["value"] == "pypi.org"
    assert response["headers"]["accept"][0]["value"] == "text/html"
    assert "authorization" not in response["headers"]


@patch("index.s3_client")
def test_local_package_shadows_upstream(mock_s3, setup_test_environment):
    """Verify locally hosted packages are never resolved from upstream (dependency confusion)."""
    index.UPSTREAM_ENABLED = True
    mock_listing(mock_s3)

    response = handler(create_cloudfront_event("/simple/requests/"), None)

    assert response["status"] == "200"
    assert "requests-2.28.1-py3-none-any.whl" in response["body"]


def test_upstream_custom_path_is_preserved(setup_test_environment):
    """Verify a mirror URL with a custom base path is honoured."""
    index.UPSTREAM_INDEX_URL = "https://mirror.example.com/pypi/simple/"
    request = create_cloudfront_event("/simple/six")["Records"][0]["cf"]["request"]

    routed = index.route_to_upstream(request, "Six")

    assert routed["uri"] == "/pypi/simple/six/"
    assert routed["origin"]["custom"]["domainName"] == "mirror.example.com"


def test_viewer_request_passthrough_when_auth_disabled(setup_test_environment):
    """Verify the viewer trigger is a no-op when authentication is disabled."""
    response = handler(create_cloudfront_event("/simple/", "viewer-request"), None)

    assert response["uri"] == "/simple/"


@patch("index.secrets_client")
def test_viewer_request_rejects_missing_credentials(mock_sm, setup_test_environment):
    """Verify requests without credentials get a Basic Auth challenge."""
    index.AUTH_ENABLED = True
    mock_sm.get_secret_value.return_value = {"SecretString": '{"alice": "secret"}'}

    response = handler(create_cloudfront_event("/simple/", "viewer-request"), None)

    assert response["status"] == "401"
    assert response["headers"]["www-authenticate"][0]["value"].startswith("Basic ")


@patch("index.secrets_client")
def test_viewer_request_rejects_wrong_password(mock_sm, setup_test_environment):
    """Verify invalid credentials are rejected."""
    index.AUTH_ENABLED = True
    mock_sm.get_secret_value.return_value = {"SecretString": '{"alice": "secret"}'}

    event = create_cloudfront_event(
        "/simple/", "viewer-request", basic_auth_headers("alice", "wrong")
    )
    response = handler(event, None)

    assert response["status"] == "401"


@patch("index.secrets_client")
def test_viewer_request_accepts_valid_credentials(mock_sm, setup_test_environment):
    """Verify valid credentials pass the request through, and the secret is cached."""
    index.AUTH_ENABLED = True
    mock_sm.get_secret_value.return_value = {"SecretString": '{"alice": "se:cret"}'}

    for _ in range(2):
        event = create_cloudfront_event(
            "/six/six-1.17.0-py2.py3-none-any.whl",
            "viewer-request",
            basic_auth_headers("alice", "se:cret"),
        )
        response = handler(event, None)
        assert response["uri"] == "/six/six-1.17.0-py2.py3-none-any.whl"

    mock_sm.get_secret_value.assert_called_once()


@patch("index.secrets_client")
def test_viewer_request_fails_closed_when_secret_unavailable(
    mock_sm, setup_test_environment
):
    """Verify requests are denied when credentials cannot be loaded."""
    index.AUTH_ENABLED = True
    mock_sm.get_secret_value.side_effect = Exception("AccessDenied")

    event = create_cloudfront_event(
        "/simple/", "viewer-request", basic_auth_headers("alice", "secret")
    )
    response = handler(event, None)

    assert response["status"] == "503"
