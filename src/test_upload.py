import base64
import hashlib
import json
import os
import sys
from unittest.mock import patch

import pytest
from botocore.exceptions import ClientError

sys.path.insert(0, os.path.dirname(__file__))

with patch("boto3.client"):
    import upload

BOUNDARY = "xYzZY"
CONTENT = b"PK\x03\x04 binary\r\n--not-a-boundary\r\n\x00\xff wheel"


def multipart(fields: dict, filename: str = None, content: bytes = CONTENT) -> bytes:
    body = b""
    for name, value in fields.items():
        body += (
            f'--{BOUNDARY}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
            f"{value}\r\n"
        ).encode()
    if filename is not None:
        body += (
            f'--{BOUNDARY}\r\nContent-Disposition: form-data; name="content"; '
            f'filename="{filename}"\r\nContent-Type: application/octet-stream\r\n\r\n'
        ).encode()
        body += content + b"\r\n"
    return body + f"--{BOUNDARY}--\r\n".encode()


def event(body: bytes, password: str = "secret", method: str = "POST") -> dict:
    token = base64.b64encode(f"ci:{password}".encode()).decode()
    return {
        "requestContext": {"http": {"method": method}},
        "headers": {
            "Authorization": f"Basic {token}",
            "Content-Type": f"multipart/form-data; boundary={BOUNDARY}",
        },
        "body": base64.b64encode(body).decode(),
        "isBase64Encoded": True,
    }


def upload_fields(**overrides) -> dict:
    fields = {
        ":action": "file_upload",
        "protocol_version": "1",
        "name": "My_Package",
        "version": "1.0.0",
        "sha256_digest": hashlib.sha256(CONTENT).hexdigest(),
        "md5_digest": hashlib.md5(CONTENT).hexdigest(),
    }
    fields.update(overrides)
    return fields


@pytest.fixture(autouse=True)
def clients():
    upload._credentials_cache.update(value=None, expires_at=0.0)
    upload._distribution_id_cache.update(value=None)
    with patch.object(upload, "s3_client") as s3, patch.object(
        upload, "secrets_client"
    ) as secrets, patch.object(upload, "ssm_client") as ssm, patch.object(
        upload, "cloudfront_client"
    ) as cloudfront:
        secrets.get_secret_value.return_value = {
            "SecretString": json.dumps({"ci": "secret"})
        }
        ssm.get_parameter.return_value = {"Parameter": {"Value": "E123"}}
        s3.get_paginator.return_value.paginate.return_value = [
            {"CommonPrefixes": [{"Prefix": "requests/"}]}
        ]
        yield {"s3": s3, "cloudfront": cloudfront}


def test_parse_multipart_keeps_binary_content():
    fields, files = upload.parse_multipart(
        multipart({"name": "pkg"}, "pkg-1.0.tar.gz"),
        f'multipart/form-data; boundary="{BOUNDARY}"',
    )
    assert fields == {"name": "pkg"}
    assert files["content"] == ("pkg-1.0.tar.gz", CONTENT)


@pytest.mark.parametrize(
    "filename, expected",
    [
        ("my_package-1.0.0-py3-none-any.whl", "my_package"),
        ("my-package-1.0.0.tar.gz", "my-package"),
        ("my.package-1.0.0.zip", "my.package"),
    ],
)
def test_distribution_name(filename, expected):
    assert upload.distribution_name(filename) == expected


def test_upload_stores_file_and_invalidates_index(clients):
    result = upload.handler(
        event(multipart(upload_fields(), "my_package-1.0.0-py3-none-any.whl")), None
    )

    assert result["statusCode"] == 200
    put = clients["s3"].put_object.call_args.kwargs
    assert put["Key"] == "my-package/my_package-1.0.0-py3-none-any.whl"
    assert put["Body"] == CONTENT
    assert put["IfNoneMatch"] == "*"
    assert put["Metadata"] == {"sha256": hashlib.sha256(CONTENT).hexdigest()}

    invalidation = clients["cloudfront"].create_invalidation.call_args.kwargs
    assert invalidation["DistributionId"] == "E123"
    assert "/simple/my-package/" in invalidation["InvalidationBatch"]["Paths"]["Items"]


def test_upload_uses_existing_package_folder(clients):
    clients["s3"].get_paginator.return_value.paginate.return_value = [
        {"CommonPrefixes": [{"Prefix": "My_Package/"}]}
    ]
    upload.handler(event(multipart(upload_fields(), "my-package-1.0.0.tar.gz")), None)
    assert (
        clients["s3"].put_object.call_args.kwargs["Key"]
        == "My_Package/my-package-1.0.0.tar.gz"
    )


def conflict(clients, existing_sha256: str):
    clients["s3"].put_object.side_effect = ClientError(
        {"Error": {"Code": "PreconditionFailed"}}, "PutObject"
    )
    clients["s3"].head_object.return_value = {"Metadata": {"sha256": existing_sha256}}


def test_existing_file_is_not_overwritten(clients):
    conflict(clients, "other")
    result = upload.handler(
        event(multipart(upload_fields(), "my_package-1.0.0-py3-none-any.whl")), None
    )
    assert result["statusCode"] == 409
    assert "already exists" in result["body"]
    clients["cloudfront"].create_invalidation.assert_not_called()


def test_identical_reupload_succeeds(clients):
    conflict(clients, hashlib.sha256(CONTENT).hexdigest())
    result = upload.handler(
        event(multipart(upload_fields(), "my_package-1.0.0-py3-none-any.whl")), None
    )
    assert result["statusCode"] == 200


def test_wrong_password_is_rejected(clients):
    result = upload.handler(
        event(multipart(upload_fields(), "my_package-1.0.0-py3-none-any.whl"), "bad"),
        None,
    )
    assert result["statusCode"] == 401
    assert "WWW-Authenticate" in result["headers"]
    clients["s3"].put_object.assert_not_called()


def test_credentials_backend_failure_fails_closed():
    upload.secrets_client.get_secret_value.side_effect = Exception("boom")
    result = upload.handler(event(multipart(upload_fields(), "x-1.0.tar.gz")), None)
    assert result["statusCode"] == 503


def test_only_post_is_allowed():
    assert upload.handler(event(b"", method="GET"), None)["statusCode"] == 405


@pytest.mark.parametrize(
    "fields, filename",
    [
        (upload_fields(**{":action": "remove_pkg"}), "my_package-1.0.0.tar.gz"),
        (upload_fields(), None),
        (upload_fields(), "../my_package-1.0.0.tar.gz"),
        (upload_fields(), "my_package-1.0.0.exe"),
        (upload_fields(), "other_package-1.0.0-py3-none-any.whl"),
        (upload_fields(sha256_digest="0" * 64), "my_package-1.0.0.tar.gz"),
        (upload_fields(md5_digest="0" * 32), "my_package-1.0.0.tar.gz"),
    ],
)
def test_invalid_uploads_are_rejected(clients, fields, filename):
    result = upload.handler(event(multipart(fields, filename)), None)
    assert result["statusCode"] == 400
    clients["s3"].put_object.assert_not_called()


def test_garbage_body_is_rejected():
    bad = event(b"not multipart")
    bad["headers"]["Content-Type"] = "text/plain"
    assert upload.handler(bad, None)["statusCode"] == 400
