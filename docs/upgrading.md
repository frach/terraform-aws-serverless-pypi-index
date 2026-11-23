# Upgrading from pre-release versions

The Lambda moved from `terraform-aws-modules/lambda` to plain resources, and the bucket policy of a created bucket moved into the S3 module. Terraform can't `moved`-refactor across external module packages, so move the state by hand **before** the first apply. Otherwise the Lambda@Edge function gets recreated, and deleting the old one fails for hours while its replicas are being cleaned up.

```bash
M=module.pypi   # address of this module in your configuration
terraform state mv "$M.module.lambda_function.aws_lambda_function.this[0]"         "$M.aws_lambda_function.edge"
terraform state mv "$M.module.lambda_function.aws_iam_role.lambda[0]"               "$M.aws_iam_role.lambda_edge"
terraform state mv "$M.module.lambda_function.aws_iam_role_policy.additional_json[0]" "$M.aws_iam_role_policy.lambda_edge"
terraform state mv "$M.module.lambda_function.aws_iam_role_policy.logs[0]"          "$M.aws_iam_role_policy.lambda_edge_logs"
terraform state mv "$M.module.lambda_function.aws_cloudwatch_log_group.lambda[0]"   "$M.aws_cloudwatch_log_group.lambda_edge"

# s3_create_bucket = true
terraform state mv "$M.aws_s3_bucket_policy.s3_bucket_policy" "$M.module.s3_bucket.aws_s3_bucket_policy.this[0]"
# s3_create_bucket = false
terraform state mv "$M.aws_s3_bucket_policy.s3_bucket_policy" "$M.aws_s3_bucket_policy.s3_bucket_policy[0]"
```

Also:
* Remove `aws_region` and `s3_attach_policy` from your module call. Set the region on your `aws` provider instead.
* `s3_force_destroy` now defaults to `false`.
* The bucket policy no longer grants `s3:*` to whoever ran `terraform apply`. List admin principals in `s3_admin_principal_arns` if you need it.
