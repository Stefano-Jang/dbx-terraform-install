# =====================================================================
# 6.3.1 Storage Credential & External Location
# =====================================================================
# UC storage credential (위에서 만든 IAM role 사용)
resource "databricks_storage_credential" "uc_catalog" {
  provider = databricks.workspace
  name     = "${local.prefix}-uc-cred"
  aws_iam_role {
    role_arn = aws_iam_role.uc_catalog.arn
  }
  comment = "UC managed default catalog credential"
  # 재할당 전파 완료 후 생성 → 올바른(새로 할당된) metastore에 credential이 만들어짐
  depends_on = [time_sleep.metastore_assignment_propagation]
}

# External location = 버킷 경로 + credential
resource "databricks_external_location" "uc_catalog" {
  provider        = databricks.workspace
  name            = "${local.prefix}-uc-catalog-loc"
  url             = "s3://${aws_s3_bucket.uc_catalog.bucket}/catalog-root"
  credential_name = databricks_storage_credential.uc_catalog.id
  comment         = "Managed location for default catalog"
  depends_on      = [time_sleep.metastore_assignment_propagation]
}

# =====================================================================
# 6.3.2 Default Catalog를 지정한 Root Bucket 위치로 생성
# =====================================================================
# managed default catalog: storage_root로 root bucket 위치 지정
resource "databricks_catalog" "default" {
  provider       = databricks.workspace
  name           = local.uc_catalog_name
  storage_root   = databricks_external_location.uc_catalog.url # ← root bucket 위치 지정
  comment        = "Managed default catalog for aws-rnd-root"
  isolation_mode = "OPEN"
  force_destroy  = true

  depends_on = [
    databricks_external_location.uc_catalog,
  ]
}

# 이 카탈로그를 워크스페이스의 기본(default) 카탈로그로 설정
resource "databricks_default_namespace_setting" "this" {
  provider = databricks.workspace
  namespace {
    value = databricks_catalog.default.name
  }
}

output "default_catalog_storage_location" {
  value = databricks_catalog.default.storage_location
}
