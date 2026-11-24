import base64
import hashlib
import hmac
import json
import os
import re
import time
import uuid
from email.message import Message

import boto3
from botocore.exceptions import ClientError

# Regional Lambda behind a Lambda function URL, reached through CloudFront at /upload/.
# It speaks the legacy PyPI upload API used by twine, uv publish and poetry publish
BUCKET_NAME = os.environ.get("BUCKET_NAME", "my-test-pypi-bucket")
CREDENTIALS_SECRET_ID = os.environ.get("CREDENTIALS_SECRET_ID")
DISTRIBUTION_ID_PARAMETER = os.environ.get("DISTRIBUTION_ID_PARAMETER")
CREDENTIALS_CACHE_TTL = int(os.environ.get("CREDENTIALS_CACHE_TTL", "300"))
AUTH_REALM = os.environ.get("AUTH_REALM", "Private PyPI")

s3_client = boto3.client("s3")
secrets_client = boto3.client("secretsmanager")
ssm_client = boto3.client("ssm")
cloudfront_client = boto3.client("cloudfront")

_credentials_cache = {"value": None, "expires_at": 0.0}
_distribution_id_cache = {"value": None}

# Wheels, sdists and legacy zip sdists only
FILENAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+!-]*\.(whl|tar\.gz|zip)$")


def normalize_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def response(status: int, body: str, headers: dict = None) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/plain; charset=utf-8", **(headers or {})},
        "body": body,
    }


# --------------------------#
#      AUTHENTICATION      #
# --------------------------#
def get_credentials() -> dict:
    now = time.time()
    if (
        _credentials_cache["value"] is not None
        and now < _credentials_cache["expires_at"]
    ):
        return _credentials_cache["value"]

    secret = secrets_client.get_secret_value(SecretId=CREDENTIALS_SECRET_ID)
    credentials = json.loads(secret["SecretString"])
    if not isinstance(credentials, dict):
        raise ValueError("Secret must be a JSON object of username/password pairs")

    _credentials_cache["value"] = credentials
    _credentials_cache["expires_at"] = now + CREDENTIALS_CACHE_TTL
    return credentials


def is_authorized(headers: dict) -> bool:
    scheme, _, encoded = headers.get("authorization", "").partition(" ")
    if scheme.lower() != "basic" or not encoded:
        return False
    try:
        decoded = base64.b64decode(encoded.strip(), validate=True).decode("utf-8")
    except Exception:
        return False

    username, sep, password = decoded.partition(":")
    if not sep:
        return False

    expected = get_credentials().get(username)
    if not isinstance(expected, str):
        return False
    return hmac.compare_digest(password.encode("utf-8"), expected.encode("utf-8"))


# --------------------------#
#         MULTIPART        #
# --------------------------#
def header_params(value: str, header: str = "content-disposition") -> Message:
    message = Message()
    message[header] = value
    return message


def parse_multipart(body: bytes, content_type: str) -> tuple:
    """Return ({field: str}, {field: (filename, bytes)}) from a multipart/form-data body."""
    boundary = header_params(content_type, "content-type").get_param(
        "boundary", header="content-type"
    )
    if not boundary:
        raise ValueError("missing multipart boundary")

    fields, files = {}, {}
    # Every delimiter is preceded by CRLF, except the first one at the very start of the body
    chunks = (b"\r\n" + body).split(b"\r\n--" + boundary.encode())
    for chunk in chunks[1:]:
        if chunk.startswith(b"--"):
            break
        head, sep, data = chunk.partition(b"\r\n\r\n")
        if not sep:
            raise ValueError("malformed multipart part")

        disposition = ""
        for line in head.decode("utf-8").split("\r\n"):
            key, _, value = line.partition(":")
            if key.strip().lower() == "content-disposition":
                disposition = value.strip()

        params = header_params(disposition)
        name = params.get_param("name", header="content-disposition")
        filename = params.get_filename()
        if name is None:
            continue
        if filename is not None:
            files[name] = (filename, data)
        else:
            fields[name] = data.decode("utf-8")

    return fields, files


# --------------------------#
#          UPLOAD          #
# --------------------------#
def distribution_name(filename: str) -> str:
    if filename.endswith(".whl"):
        return filename.split("-")[0]
    stem = (
        filename[: -len(".tar.gz")] if filename.endswith(".tar.gz") else filename[:-4]
    )
    return stem.rpartition("-")[0]


def package_folder(name: str) -> str:
    """Upload next to existing files of the package, whatever its folder is spelled like."""
    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET_NAME, Delimiter="/"):
        for prefix in page.get("CommonPrefixes", []):
            folder = prefix["Prefix"].rstrip("/")
            if normalize_name(folder) == name:
                return folder
    return name


def get_distribution_id() -> str:
    if _distribution_id_cache["value"] is None:
        parameter = ssm_client.get_parameter(Name=DISTRIBUTION_ID_PARAMETER)
        _distribution_id_cache["value"] = parameter["Parameter"]["Value"]
    return _distribution_id_cache["value"]


def invalidate_index(name: str) -> None:
    paths = ["/simple", "/simple/", f"/simple/{name}", f"/simple/{name}/"]
    try:
        cloudfront_client.create_invalidation(
            DistributionId=get_distribution_id(),
            InvalidationBatch={
                "Paths": {"Quantity": len(paths), "Items": paths},
                "CallerReference": str(uuid.uuid4()),
            },
        )
    except Exception as e:
        # The file is stored; the index catches up when its cache expires
        print(f"Invalidation failed for {name!r}: {e!r}")


def store(key: str, content: bytes, sha256: str) -> int:
    """Write the file unless the key exists. Re-uploading identical content is a no-op."""
    try:
        s3_client.put_object(
            Bucket=BUCKET_NAME,
            Key=key,
            Body=content,
            ContentType="application/octet-stream",
            Metadata={"sha256": sha256},
            IfNoneMatch="*",
        )
        return 201
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code not in ("PreconditionFailed", "ConditionalRequestConflict"):
            raise

    existing = s3_client.head_object(Bucket=BUCKET_NAME, Key=key)
    return 200 if existing.get("Metadata", {}).get("sha256") == sha256 else 409


def handle_upload(event) -> dict:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    method = event.get("requestContext", {}).get("http", {}).get("method", "")

    if method != "POST":
        return response(405, "Method Not Allowed", {"Allow": "POST"})

    try:
        authorized = is_authorized(headers)
    except Exception as e:
        print(f"Loading upload credentials failed: {e!r}")
        return response(503, "Authentication backend unavailable")
    if not authorized:
        return response(
            401,
            "Unauthorized",
            {"WWW-Authenticate": f'Basic realm="{AUTH_REALM}", charset="UTF-8"'},
        )

    body = event.get("body") or ""
    body = base64.b64decode(body) if event.get("isBase64Encoded") else body.encode()

    try:
        fields, files = parse_multipart(body, headers.get("content-type", ""))
    except Exception:
        return response(400, "Invalid multipart/form-data body")

    if fields.get(":action") != "file_upload":
        return response(400, "Unsupported :action, expected file_upload")

    name = normalize_name(fields.get("name", "").strip())
    if not name or "content" not in files:
        return response(400, "Missing name or content")

    filename, content = files["content"]
    filename = filename.strip()
    if not FILENAME_RE.match(filename):
        return response(400, f"Invalid file name: {filename}")
    if normalize_name(distribution_name(filename)) != name:
        return response(400, f"File {filename} doesn't belong to package {name}")

    sha256 = hashlib.sha256(content).hexdigest()
    expected_sha256 = fields.get("sha256_digest", "").strip().lower()
    expected_md5 = fields.get("md5_digest", "").strip().lower()
    if expected_sha256 and expected_sha256 != sha256:
        return response(400, "sha256_digest doesn't match the uploaded file")
    if expected_md5 and expected_md5 != hashlib.md5(content).hexdigest():
        return response(400, "md5_digest doesn't match the uploaded file")

    key = f"{package_folder(name)}/{filename}"
    try:
        status = store(key, content, sha256)
    except Exception as e:
        print(f"Storing {key!r} failed: {e!r}")
        return response(500, "Internal Server Error")

    if status == 409:
        # Same status as pypiserver; the message is what PyPI returns
        return response(409, f"File already exists: {filename}")

    if status == 201:
        invalidate_index(name)
    print(f"Uploaded {key!r} ({len(content)} bytes, sha256 {sha256})")
    return response(200, "OK")


def handler(event, context):
    return handle_upload(event)
