import os
import json
import re
import time
import base64
import hmac
from urllib.parse import urlparse

import boto3

# Load configuration dynamically from the sidecar JSON file packaged by Terraform
# This relies on the absolute path where the Lambda function executes
current_dir = os.path.dirname(os.path.abspath(__file__))
config_path = os.path.join(current_dir, "config.json")

if os.path.exists(config_path):
    with open(config_path, "r") as f:
        CONFIG = json.load(f)
else:
    # Local development and testing fallback values
    CONFIG = {"aws_region": "us-east-1", "bucket_name": "my-test-pypi-bucket"}

DATA_LAYER_REGION = CONFIG["aws_region"]
BUCKET_NAME = CONFIG["bucket_name"]

# Authentication settings (Lambda@Edge does not support environment variables)
AUTH_ENABLED = CONFIG.get("auth_enabled", False)
AUTH_SECRET_ID = CONFIG.get("auth_secret_id")
AUTH_REALM = CONFIG.get("auth_realm", "Private PyPI")
AUTH_CACHE_TTL = CONFIG.get("auth_cache_ttl", 300)

# Upstream proxy settings
UPSTREAM_ENABLED = CONFIG.get("upstream_enabled", False)
UPSTREAM_INDEX_URL = CONFIG.get("upstream_index_url", "https://pypi.org/simple")

s3_client = boto3.client("s3", region_name=DATA_LAYER_REGION)
secrets_client = boto3.client("secretsmanager", region_name=DATA_LAYER_REGION)

# In-memory credentials cache, kept between invocations of a warm container
_credentials_cache = {"value": None, "expires_at": 0.0}


# Normalize package names according to PEP 503.
def normalize_name(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


# Extract unique, normalized package names from flat S3 keys (package/file).
def get_all_packages(objects) -> set:
    packages = set()
    for obj in objects:
        key = obj.get("Key", "")
        if "/" in key:
            parts = key.split("/")
            # A valid file has at least a folder name and a file name component
            if len(parts) >= 2 and parts[-1]:
                raw_package_name = parts[0]
                packages.add(normalize_name(raw_package_name))
    return packages


# Generate the root PEP 503 index page (/simple/).
def generate_root_html(packages: set) -> str:
    links = "".join(
        f'    <a href="{pkg}/">{pkg}</a><br/>\n' for pkg in sorted(packages)
    )

    return f"""<!DOCTYPE html>
<html>
  <head>
    <title>Simple Index</title>
  </head>
  <body>
{links}  </body>
</html>"""


# Generate the file index page for a specific package from flat S3 layout.
def generate_package_html(package_name: str, objects) -> str:
    links = ""
    normalized_target = normalize_name(package_name)

    for obj in objects:
        key = obj.get("Key", "")
        if "/" in key:
            parts = key.split("/")
            if len(parts) >= 2 and parts[-1]:
                raw_package_name = parts[0]
                filename = parts[-1]

                if normalize_name(raw_package_name) == normalized_target:
                    links += f'    <a href="/{key}">{filename}</a><br/>\n'

    return f"""<!DOCTYPE html>
<html>
  <head>
    <title>Links for {package_name}</title>
  </head>
  <body>
    <h1>Links for {package_name}</h1>
{links}
  </body>
</html>"""


# List every object in the bucket (list_objects_v2 returns at most 1000 keys per call).
def list_all_objects() -> list:
    objects = []
    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET_NAME):
        objects.extend(page.get("Contents", []))
    return objects


def html_response(status: str, description: str, body: str) -> dict:
    return {
        "status": status,
        "statusDescription": description,
        "headers": {
            "content-type": [
                {"key": "Content-Type", "value": "text/html; charset=utf-8"}
            ]
        },
        "body": body,
    }


# --------------------------#
#      AUTHENTICATION      #
# --------------------------#
# Fetch the {"username": "password"} map from Secrets Manager, cached for AUTH_CACHE_TTL seconds.
def get_credentials() -> dict:
    now = time.time()
    if (
        _credentials_cache["value"] is not None
        and now < _credentials_cache["expires_at"]
    ):
        return _credentials_cache["value"]

    try:
        secret = secrets_client.get_secret_value(SecretId=AUTH_SECRET_ID)
        credentials = json.loads(secret["SecretString"])
        if not isinstance(credentials, dict):
            raise ValueError("Secret must be a JSON object of username/password pairs")
    except Exception:
        # Serve stale credentials rather than locking everyone out on a transient error
        if _credentials_cache["value"] is not None:
            return _credentials_cache["value"]
        raise

    _credentials_cache["value"] = credentials
    _credentials_cache["expires_at"] = now + AUTH_CACHE_TTL
    return credentials


def parse_basic_auth(request) -> tuple:
    headers = request.get("headers", {})
    values = headers.get("authorization", [])
    if not values:
        return None, None

    scheme, _, encoded = values[0]["value"].partition(" ")
    if scheme.lower() != "basic" or not encoded:
        return None, None

    try:
        decoded = base64.b64decode(encoded.strip(), validate=True).decode("utf-8")
    except Exception:
        return None, None

    username, sep, password = decoded.partition(":")
    if not sep:
        return None, None
    return username, password


def is_authorized(request) -> bool:
    username, password = parse_basic_auth(request)
    if username is None:
        return False

    expected = get_credentials().get(username)
    if not isinstance(expected, str):
        return False
    return hmac.compare_digest(password.encode("utf-8"), expected.encode("utf-8"))


def unauthorized_response() -> dict:
    return {
        "status": "401",
        "statusDescription": "Unauthorized",
        "headers": {
            "www-authenticate": [
                {
                    "key": "WWW-Authenticate",
                    "value": f'Basic realm="{AUTH_REALM}", charset="UTF-8"',
                }
            ],
            "content-type": [{"key": "Content-Type", "value": "text/plain"}],
        },
        "body": "Unauthorized",
    }


# Viewer-request: runs on every request (cache hits included), so it guards everything.
def handle_viewer_request(request):
    if not AUTH_ENABLED:
        return request

    try:
        authorized = is_authorized(request)
    except Exception:
        # Fail closed when credentials cannot be loaded
        return {
            "status": "503",
            "statusDescription": "Service Unavailable",
            "headers": {
                "content-type": [{"key": "Content-Type", "value": "text/plain"}]
            },
            "body": "Authentication backend unavailable",
        }

    return request if authorized else unauthorized_response()


# --------------------------#
#      UPSTREAM PROXY      #
# --------------------------#
# Re-target the request to the upstream index, so CloudFront fetches (and caches) its page.
def route_to_upstream(request, package_name: str):
    upstream = urlparse(UPSTREAM_INDEX_URL)
    base_path = upstream.path.rstrip("/")

    request["origin"] = {
        "custom": {
            "domainName": upstream.hostname,
            "port": upstream.port or 443,
            "protocol": "https",
            "path": "",
            "sslProtocols": ["TLSv1.2"],
            "readTimeout": 30,
            "keepaliveTimeout": 5,
            "customHeaders": {},
        }
    }
    request["uri"] = f"{base_path}/{normalize_name(package_name)}/"
    request["querystring"] = ""

    headers = request.setdefault("headers", {})
    headers["host"] = [{"key": "Host", "value": upstream.hostname}]
    # Cache key ignores Accept, so always ask for the PEP 503 HTML flavour
    headers["accept"] = [{"key": "Accept", "value": "text/html"}]
    headers.pop("authorization", None)
    return request


# Origin-request: runs on cache misses only; generated responses are cached by CloudFront.
def handle_origin_request(request):
    uri = request["uri"].strip("/")

    if not BUCKET_NAME or BUCKET_NAME.startswith("${"):
        return html_response(
            "500",
            "Internal Server Error",
            "Missing BUCKET_NAME template configuration.",
        )

    # Clean empty strings from split lists to handle trailing slashes robustly
    parts = [p for p in uri.split("/") if p]

    if not parts or parts[0] != "simple" or len(parts) > 2:
        return request

    try:
        objects = list_all_objects()
    except Exception as e:
        return html_response("500", "Internal Server Error", f"S3 Error: {str(e)}")

    # Case 1: Root simple index page (/simple or /simple/)
    if len(parts) == 1:
        packages = get_all_packages(objects)
        return html_response("200", "OK", generate_root_html(packages))

    # Case 2: Specific package file index page (/simple/package-name or /simple/package-name/)
    package_name = parts[1]
    if normalize_name(package_name) in get_all_packages(objects):
        # Local packages always win, so a private name can never be shadowed by upstream
        return html_response("200", "OK", generate_package_html(package_name, objects))

    if UPSTREAM_ENABLED:
        return route_to_upstream(request, package_name)

    return html_response("404", "Not Found", f"Package {package_name} not found")


# MAIN HANDLER
def handler(event, context):
    cf = event["Records"][0]["cf"]
    request = cf["request"]
    event_type = cf.get("config", {}).get("eventType", "origin-request")

    if event_type == "viewer-request":
        return handle_viewer_request(request)
    return handle_origin_request(request)
