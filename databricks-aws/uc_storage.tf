# UC managed catalog root 버킷
resource "aws_s3_bucket" "uc_catalog" {
  bucket        = local.uc_catalog_bucket_name
  force_destroy = true
  tags          = merge(var.tags, { Name = local.uc_catalog_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "uc_catalog" {
  bucket                  = aws_s3_bucket.uc_catalog.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# UC 스토리지 접근용 IAM Role
# self-assuming trust policy가 필요 (UC 요구사항)
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "uc_catalog" {
  name = "${local.prefix}-uc-catalog-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # Databricks UC 전용 AWS 계정
          AWS = "arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.databricks_account_id
          }
        }
      },
      # self-assume (UC 요구사항)
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.prefix}-uc-catalog-role"
          }
        }
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "uc_catalog" {
  name = "${local.prefix}-uc-catalog-policy"
  role = aws_iam_role.uc_catalog.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketLocation",
          "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration"
        ]
        Resource = [
          aws_s3_bucket.uc_catalog.arn,
          "${aws_s3_bucket.uc_catalog.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [aws_iam_role.uc_catalog.arn]
      }
    ]
  })
}
