import sys
import pytest

def pytest_configure(config):
    """
    Executes before any test or module import occurs.
    Intercepts and mocks the raw Terraform string tokens inside src.index in-memory.
    """
    # Define valid mock configurations for local testing execution loops
    mock_vars = {
        "${secret_name}": "serverless-pypi-credentials",
        "${bucket_name}": "frach-private-pypi-storage-bucket",
        "${aws_region}": "eu-west-1" # Keeps botocore happy locally
    }

    # Read the production file content
    with open("src/index.py", "r") as f:
        code_content = f.read()

    # Perform a string replacement for all Terraform template placeholders
    for placeholder, mock_value in mock_vars.items():
        code_content = code_content.replace(placeholder, mock_value)

    # Dynamically compile and inject the modified code directly into the Python module cache
    import types
    module = types.ModuleType("src.index")
    exec(code_content, module.__dict__)
    sys.modules["src.index"] = module
