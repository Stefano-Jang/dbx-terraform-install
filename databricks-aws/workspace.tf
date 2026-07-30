resource "databricks_mws_workspaces" "this" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  aws_region     = var.region
  workspace_name = local.prefix
  # deployment_name → workspace URL의 일부가 됩니다.
  #   최종 URL: https://<account-prefix>-<deployment_name>.cloud.databricks.com
  #   (<account-prefix>는 Databricks가 Account에 등록해준 값. deployment_name 앞에 붙음)
  # local.prefix에 suffix가 포함되므로 도메인도 SA마다 고유해집니다.
  # ⚠️ deployment_name은 Account에 "deployment name prefix"가 먼저 등록돼야 사용 가능합니다.
  #    이 prefix는 self-service가 불가하며 Databricks 담당자에게 요청해야 합니다
  #    (등록 후 새로 생성되는 워크스페이스부터 적용). 그래서 기본값은 미설정(null)이며,
  #    미설정 시 Databricks가 dbc-xxxxxxxx 형태로 URL을 자동 발급합니다.
  #    var.set_deployment_name=true 로 켜면 local.prefix가 deployment_name으로 사용됩니다.
  deployment_name = var.set_deployment_name ? local.prefix : null
  pricing_tier    = "ENTERPRISE" # PrivateLink는 ENTERPRISE 필요

  credentials_id           = databricks_mws_credentials.this.credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this.storage_configuration_id
  network_id               = databricks_mws_networks.this.network_id

  # backend PrivateLink 연결
  private_access_settings_id = databricks_mws_private_access_settings.pas.private_access_settings_id

  depends_on = [
    databricks_mws_networks.this,
  ]
}

output "workspace_url" {
  value = databricks_mws_workspaces.this.workspace_url
}

output "workspace_id" {
  value = databricks_mws_workspaces.this.workspace_id
}

output "workspace_name" {
  value = databricks_mws_workspaces.this.workspace_name
}

# 이번 배포에 실제로 적용된 이름들을 한 번에 확인
output "resolved_names" {
  value = {
    suffix               = local.suffix # "-xxxxxx" 또는 ""
    prefix               = local.prefix # 리소스 공통 접두어
    workspace_name       = local.prefix
    root_bucket          = "${local.prefix}-rootbucket"
    uc_catalog_bucket    = local.uc_catalog_bucket_name
    uc_catalog_root_path = "s3://${local.uc_catalog_bucket_name}/catalog-root"
    uc_catalog_name      = local.uc_catalog_name
    metastore_id         = local.metastore_id
    metastore_reused     = !local.create_metastore # true면 기존 metastore 재활용
  }
}
