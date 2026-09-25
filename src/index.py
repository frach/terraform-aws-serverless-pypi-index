import base64
import json
import boto3
from botocore.exceptions import ClientError

# --- GLOBAL CONFIGURATION & CACHE LAYER (INJECTED BY TERRAFORM) ---
SECRET_NAME = "${secret_name}" 
BUCKET_NAME = "${bucket_name}"
DATA_LAYER_REGION = "${aws_region}"

CACHED_CREDENTIALS = None
s3_client = boto3.client('s3', region_name=DATA_LAYER_REGION)

def get_secret_credentials():
    global CACHED_CREDENTIALS
    if CACHED_CREDENTIALS:
        return CACHED_CREDENTIALS

    print(f"Cache miss. Interrogating AWS Secrets Manager secure storage path for '{SECRET_NAME}' in {DATA_LAYER_REGION}...")
    session = boto3.session.Session()
    client = session.client(service_name='secretsmanager', region_name=DATA_LAYER_REGION)
    try:
        response = client.get_secret_value(SecretId=SECRET_NAME)
        if 'SecretString' in response:
            secret_data = json.loads(response['SecretString'])
            CACHED_CREDENTIALS = {
                "username": secret_data.get("username", "admin"),
                "password": secret_data.get("password", "")
            }
            return CACHED_CREDENTIALS
    except ClientError as e:
        print(f"Critical error executing GetSecretValue tracking runtime hooks: {e}")
        raise e

def generate_html_index(title, links):
    """
    Generates a strict, well-formed PEP 503 compliant HTML5 document.
    """
    html_links = "".join([f'<a href="{l}">{l.split("/")[-1] if not l.endswith("/") else l.split("/")[-2]}</a><br/>\n' for l in links])
    content = f"""<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Links for {title}</title>
  </head>
  <body>
    <h1>Links for {title}</h1>
    {html_links}
  </body>
</html>"""
    return content

def handler(event, context):
    request = event['Records']['cf']['request']
    headers = request['headers']
    raw_uri = request['uri']

    # 1. PEP 503 MANDATORY DIRECTORY TRAILING SLASH REDIRECT GUARD
    # If the user requests a directory index (/simple or /simple/six) WITHOUT a trailing slash,
    # we MUST enforce an HTTP 301 Redirect to the version with the trailing slash.
    # Otherwise, package installers like 'pip' will reject the returned HTML payload content.
    last_path_segment = raw_uri.split('/')[-1] if raw_uri else ""
    if not raw_uri.endswith('/') and '.' not in last_path_segment:
        return {
            'status': '301',
            'statusDescription': 'Moved Permanently',
            'headers': {
                'location': [{'key': 'Location', 'value': f"{raw_uri}/"}]
            }
        }

    uri = raw_uri.strip('/')

    # 2. OPTIONAL BASIC AUTHENTICATION VALIDATION GUARD
    auth_header = headers.get('authorization')
    if auth_header:
        try:
            creds = get_secret_credentials()
            raw_token = f"{creds['username']}:{creds['password']}"
            encoded_token = base64.b64encode(raw_token.encode('utf-8')).decode('utf-8')
            expected_auth = f"Basic {encoded_token}"
        except Exception as e:
            print(f"Internal security sub-system execution tracking failure: {e}")
            return {'status': '500', 'statusDescription': 'Internal Server Error', 'body': 'Security validation platform offline.'}

        if auth_header['value'] != expected_auth:
            return {
                'status': '401', 
                'statusDescription': 'Unauthorized',
                'body': 'Private Serverless PyPi - Invalid Access Token Provided.',
                'headers': {'www-authenticate': [{'key': 'WWW-Authenticate', 'value': 'Basic realm="Private PyPi"'}]}
            }
        
        del headers['authorization']

    # 3. APPLICATION ROUTING: PASSTHROUGH ARTIFACT REQUESTS VS ON-THE-FLY INDEX COMPILATION
    if '.' in last_path_segment and not raw_uri.endswith('/'):
        if 'authorization' in headers:
            del headers['authorization']
        request['uri'] = f"/{uri}"
        return request

    # 4. ON-THE-FLY DIRECTORY INDEX GENERATION VIA LIVE AMAZON S3 API EVALUATIONS
    prefix = "" if uri == "simple" or uri == "" else f"{uri.replace('simple/', '')}/"
    
    try:
        paginator = s3_client.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=BUCKET_NAME, Prefix=prefix, Delimiter='/')
        
        discovered_links = []
        for page in pages:
            if prefix == "":
                for common_prefix in page.get('CommonPrefixes', []):
                    pkg_name = common_prefix.get('Prefix').strip('/')
                    discovered_links.append(f"/simple/{pkg_name}/")
            else:
                for obj in page.get('Contents', []):
                    key = obj.get('Key')
                    if key and not key.endswith('/'):
                        discovered_links.append(f"/{key}")

        if not discovered_links:
            return {
                'status': '404',
                'statusDescription': 'Not Found',
                'body': f'Package or repository tracking index empty for target: {uri}'
            }

        index_title = uri if uri else "Root Index"
        html_body = generate_html_index(index_title, sorted(list(set(discovered_links))))

        return {
            'status': '200',
            'statusDescription': 'OK',
            'headers': {
                'content-type': [{'key': 'Content-Type', 'value': 'text/html; charset=utf-8'}],
                'cache-control': [{'key': 'Cache-Control', 'value': 'public, max-age=60'}]
            },
            'body': html_body
        }

    except Exception as e:
        print(f"Dynamic directory generation mapping collapse: {e}")
        return {'status': '500', 'statusDescription': 'Internal Server Error', 'body': 'Failed to compile remote cluster index metrics.'}
