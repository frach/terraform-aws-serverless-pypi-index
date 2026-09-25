# Terraform string template variables
DATA_LAYER_REGION = "${aws_region}" 
BUCKET_NAME = "${bucket_name}"

import os
import re
import boto3

s3_client = boto3.client("s3", region_name=DATA_LAYER_REGION)


def normalize_name(name: str) -> str:
    """Normalize package names according to PEP 503."""
    return re.sub(r"[-_.]+", "-", name).lower()


def get_all_packages(objects) -> set:
    """Extract unique, normalized package names from S3 keys."""
    packages = set()
    for obj in objects:
        key = obj.get("Key", "")
        # Expected S3 format: packages/package_name/file.whl
        if key.startswith("packages/") and len(key.split("/")) >= 3:
            parts = key.split("/")
            raw_package_name = parts[1]
            packages.add(normalize_name(raw_package_name))
    return packages


def generate_root_html(packages: set) -> str:
    """Generate the root PEP 503 index page (/simple/)."""
    links = "".join(f'<a href="{pkg}/">{pkg}</a><br/>\n' for pkg in sorted(packages))
    return f"<!DOCTYPE html>\n<html>\n  <head>\n    <title>Simple Index</title>\n  </head>\n  <body>\n    {links}  </body>\n</html>"


def generate_package_html(package_name: str, objects) -> str:
    """Generate the file index page for a specific package (/simple/package-name/)."""
    links = ""
    normalized_target = normalize_name(package_name)
    
    for obj in objects:
        key = obj.get("Key", "")
        if key.startswith("packages/") and len(key.split("/")) >= 3:
            parts = key.split("/")
            raw_package_name = parts[1]
            filename = parts[-1]
            
            if normalize_name(raw_package_name) == normalized_target and filename:
                # Links point to the CloudFront distribution path where the actual S3 objects reside
                links += f'<a href="/{key}">{filename}</a><br/>\n'
                
    return f"<!DOCTYPE html>\n<html>\n  <head>\n    <title>Links for {package_name}</title>\n  </head>\n  <body>\n    <h1>Links for {package_name}</h1>\n    {links}  </body>\n</html>"


def handler(event, context):
    request = event["Records"][0]["cf"]["request"]
    uri = request["uri"].strip("/")
    
    # Handle missing bucket environment variable configuration
    if not BUCKET_NAME or BUCKET_NAME.startswith("${"):
        return {
            "status": "500",
            "statusDescription": "Internal Server Error",
            "headers": {"content-type": [{"key": "Content-Type", "value": "text/html"}]},
            "body": "Missing BUCKET_NAME template configuration."
        }

    # Fetch objects from S3 under the 'packages/' prefix
    try:
        response = s3_client.list_objects_v2(Bucket=BUCKET_NAME, Prefix="packages/")
        objects = response.get("Contents", [])
    except Exception as e:
        return {
            "status": "500",
            "statusDescription": "Internal Server Error",
            "headers": {"content-type": [{"key": "Content-Type", "value": "text/html"}]},
            "body": f"S3 Error: {str(e)}"
        }

    # Routing logic
    parts = uri.split("/")
    
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
        
    # Case 2: Specific package file index page (/simple/package-name)
    elif len(parts) == 2 and parts[0] == "simple":
        package_name = parts[1]
        html_content = generate_package_html(package_name, objects)
        return {
            "status": "200",
            "statusDescription": "OK",
            "headers": {"content-type": [{"key": "Content-Type", "value": "text/html; charset=utf-8"}]},
            "body": html_content
        }

    # If the URL path does not match the /simple standard, allow standard passthrough (e.g., direct download from S3)
    return request
