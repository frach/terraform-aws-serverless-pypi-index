import sys
import os
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
    {"Key": "root_level_ignored.txt"}  # Files at root with no folder split are skipped
]

def create_cloudfront_event(uri: str):
    """Helper utility to generate standard Lambda@Edge payload structure."""
    return {
        "Records": [
            {
                "cf": {
                    "request": {
                        "uri": uri,
                        "method": "GET",
                        "clientIp": "1.2.3.4",
                        "headers": {}
                    }
                }
            }
        ]
    }

@pytest.fixture(autouse=True)
def setup_test_environment():
    """Dynamically set default configurations for testing execution."""
    index.BUCKET_NAME = "terraform-b31a35574fb1b63ac4e6cf477f"
    index.DATA_LAYER_REGION = "us-east-1"
    yield

@patch("index.s3_client")
def test_lambda_returns_root_simple_index(mock_s3, setup_test_environment):
    """Verify that /simple/ returns a valid, normalized root directory list of packages."""
    mock_s3.list_objects_v2.return_value = {"Contents": MOCK_S3_CONTENTS}
    
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
    mock_s3.list_objects_v2.return_value = {"Contents": MOCK_S3_CONTENTS}
    
    event = create_cloudfront_event("/simple/six")
    response = handler(event, None)
    
    assert response["status"] == "200"
    # FIXED: Aligned with your list array element evaluation syntax [0]
    assert "text/html" in response["headers"]["content-type"][0]["value"]
    
    body = response["body"]
    assert "Links for six" in body
    assert '<a href="/six/six-1.17.0-py2.py3-none-any.whl">six-1.17.0-py2.py3-none-any.whl</a>' in body
    assert "Flask_SQLAlchemy" not in body

@patch("index.s3_client")
def test_lambda_handles_package_normalization_in_routing(mock_s3, setup_test_environment):
    """Verify routing correctly applies PEP 503 translation rules on misaligned input targets."""
    mock_s3.list_objects_v2.return_value = {"Contents": MOCK_S3_CONTENTS}
    
    event = create_cloudfront_event("/simple/flask-sqlalchemy")
    response = handler(event, None)
    
    assert response["status"] == "200"
    body = response["body"]
    assert '<a href="/Flask_SQLAlchemy/Flask_SQLAlchemy-3.0.2-py3-none-any.whl">' in body

@patch("index.s3_client")
def test_lambda_passthrough_for_other_urls(mock_s3, setup_test_environment):
    """Verify paths unrelated to /simple yield standard request objects for native handling."""
    mock_s3.list_objects_v2.return_value = {"Contents": MOCK_S3_CONTENTS}
    
    event = create_cloudfront_event("/six/six-1.17.0-py2.py3-none-any.whl")
    response = handler(event, None)
    
    assert "uri" in response
    assert response["uri"] == "/six/six-1.17.0-py2.py3-none-any.whl"
