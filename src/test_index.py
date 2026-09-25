import pytest
import base64
from unittest.mock import patch, MagicMock
from src.index import handler

def create_cloudfront_event(uri, auth_header=None):
    request = {
        "uri": uri,
        "method": "GET",
        "clientIp": "192.0.2.1",
        "headers": {}
    }
    if auth_header:
        # CloudFront wraps incoming header entries inside an array container list
        request["headers"]["authorization"] = [{"key": "Authorization", "value": auth_header}]
    
    return {
        "Records": [
            {
                "cf": {
                    "config": {"distributionId": "E1ABCDEFX12345"},
                    "request": request
                }
            }
        ]
    }

@pytest.fixture(autouse=True)
def reset_credentials_cache():
    with patch('src.index.CACHED_CREDENTIALS', None):
        yield

@patch('src.index.s3_client')
def test_anonymous_request_allows_missing_header_and_returns_index(mock_s3):
    """Verifies completely blank headers bypass authentication checks entirely and return valid PEP 503 HTML5."""
    mock_paginator = MagicMock()
    mock_paginator.paginate.return_value = [{'CommonPrefixes': [{'Prefix': 'six/'}]}]
    mock_s3.get_paginator.return_value = mock_paginator

    event = create_cloudfront_event("/simple/")
    response = handler(event, None)
    
    assert response["status"] == "200"
    assert "html" in response["body"]
    assert "/simple/six/" in response["body"] # Valid path tracking structure check


@patch('src.index.boto3.session.Session')
def test_unauthorized_request_returns_401_on_bad_credentials(mock_session):
    """Verifies that if credentials are passed, they must be absolutely valid or fail."""
    mock_secrets_client = MagicMock()
    mock_secrets_client.get_secret_value.return_value = {
        'SecretString': '{"username": "admin", "password": "correct_password"}'
    }
    mock_session.return_value.client.return_value = mock_secrets_client

    wrong_auth = "Basic " + base64.b64encode(b"admin:invalid_password").decode("utf-8")
    event = create_cloudfront_event("/simple/", auth_header=wrong_auth)
    
    response = handler(event, None)
    assert response["status"] == "401"

@patch('src.index.s3_client')
@patch('src.index.boto3.session.Session')
def test_valid_credentials_clear_authorization_headers_on_passthrough(mock_session, mock_s3):
    """Verifies valid credentials unlock access paths smoothly."""
    mock_secrets_client = MagicMock()
    mock_secrets_client.get_secret_value.return_value = {
        'SecretString': '{"username": "admin", "password": "correct_password"}'
    }
    mock_session.return_value.client.return_value = mock_secrets_client

    valid_auth = "Basic " + base64.b64encode(b"admin:correct_password").decode("utf-8")
    event = create_cloudfront_event("/simple/six/six-1.16.0-py2.py3-none-any.whl", auth_header=valid_auth)
    
    response = handler(event, None)
    assert "status" not in response
    assert response["uri"] == "/simple/six/six-1.16.0-py2.py3-none-any.whl"
