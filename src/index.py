import os
import json
import re
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
    CONFIG = {
        "aws_region": "us-east-1",
        "bucket_name": "my-test-pypi-bucket"
    }

DATA_LAYER_REGION = CONFIG["aws_region"]
BUCKET_NAME = CONFIG["bucket_name"]

s3_client = boto3.client("s3", region_name=DATA_LAYER_REGION)


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
    links = "".join(f'    <a href="{pkg}/">{pkg}</a><br/>\n' for pkg in sorted(packages))

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


# MAIN HANDLER
def handler(event, context):
    request = event["Records"][0]["cf"]["request"]
    uri = request["uri"].strip("/")
    
    if not BUCKET_NAME or BUCKET_NAME.startswith("${"):
        return {
            "status": "500",
            "statusDescription": "Internal Server Error",
            "headers": {"content-type": [{"key": "Content-Type", "value": "text/html"}]},
            "body": "Missing BUCKET_NAME template configuration."
        }

    try:
        response = s3_client.list_objects_v2(Bucket=BUCKET_NAME)
        objects = response.get("Contents", [])
    except Exception as e:
        return {
            "status": "500",
            "statusDescription": "Internal Server Error",
            "headers": {"content-type": [{"key": "Content-Type", "value": "text/html"}]},
            "body": f"S3 Error: {str(e)}"
        }

    # Clean empty strings from split lists to handle trailing slashes robustly
    parts = [p for p in uri.split("/") if p]

    # Case 1: Root simple index page (/simple or /simple/)
    if len(parts) == 1 and parts[0] == "simple":
        packages = get_all_packages(objects)
        html_content = generate_root_html(packages)
        return {
            "status": "200",
            "statusDescription": "OK",
            "headers": {"content-type": [{"key": "Content-Type", "value": "text/html; charset=utf-8"}]},
            "body": html_content
        }

    # Case 2: Specific package file index page (/simple/package-name or /simple/package-name/)
    elif len(parts) == 2 and parts[0] == "simple":
        package_name = parts[1]
        html_content = generate_package_html(package_name, objects)
        return {
            "status": "200",
            "statusDescription": "OK",
            "headers": {"content-type": [{"key": "Content-Type", "value": "text/html; charset=utf-8"}]},
            "body": html_content
        }

    return request
