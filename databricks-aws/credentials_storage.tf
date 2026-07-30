# =====================================================================
# 4.1 Cross-account IAM Role (Databricks가 EC2 오케스트레이션)
# =====================================================================
data "databricks_aws_assume_role_policy" "this" {
  external_id = var.databricks_account_id
}

resource "aws_iam_role" "cross_account" {
  name               = "${local.prefix}-crossaccount-role"
  assume_role_policy = data.databricks_aws_assume_role_policy.this.json
  tags               = var.tags
}

data "databricks_aws_crossaccount_policy" "this" {}

resource "aws_iam_role_policy" "cross_account" {
  name   = "${local.prefix}-crossaccount-policy"
  role   = aws_iam_role.cross_account.id
  policy = data.databricks_aws_crossaccount_policy.this.json
}

# IAM role/policy는 생성 직후 AWS 전역 전파에 수 초~수십 초가 걸립니다.
# 전파 전에 Databricks가 role을 assume해 검증하면 "Failed credential validation
# checks" 오류가 나므로, credentials 등록 전에 충분히 대기합니다.
resource "time_sleep" "iam_propagation" {
  depends_on      = [aws_iam_role.cross_account, aws_iam_role_policy.cross_account]
  create_duration = "30s"
}

# Databricks Account에 credentials 등록
# account_id는 provider(databricks.mws) 설정에서 오므로 리소스에 지정하지 않습니다(deprecated).
resource "databricks_mws_credentials" "this" {
  provider         = databricks.mws
  credentials_name = "${local.prefix}-creds"
  role_arn         = aws_iam_role.cross_account.arn
  depends_on       = [time_sleep.iam_propagation]
}

# =====================================================================
# 4.2 Root S3 Bucket (워크스페이스 DBFS root)
# =====================================================================
resource "aws_s3_bucket" "root" {
  bucket        = "${local.prefix}-rootbucket"
  force_destroy = true
  tags          = merge(var.tags, { Name = "${local.prefix}-rootbucket" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "root" {
  bucket = aws_s3_bucket.root.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "root" {
  bucket                  = aws_s3_bucket.root.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "databricks_aws_bucket_policy" "this" {
  bucket = aws_s3_bucket.root.bucket
}

resource "aws_s3_bucket_policy" "root" {
  bucket     = aws_s3_bucket.root.id
  policy     = data.databricks_aws_bucket_policy.this.json
  depends_on = [aws_s3_bucket_public_access_block.root]
}

# Databricks Account에 storage 구성 등록
# bucket policy가 적용되기 전에 등록하면 Databricks의 버킷 접근 검증(List/Put/Delete)이
# "Access Denied"로 실패하므로, bucket policy에 명시적으로 의존시킵니다.
resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id
  storage_configuration_name = "${local.prefix}-storage"
  bucket_name                = aws_s3_bucket.root.bucket
  depends_on                 = [aws_s3_bucket_policy.root]
}
