provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# Account 레벨 (MWS = Multi-Workspace Service)
provider "databricks" {
  alias         = "mws"
  host          = "https://accounts.cloud.databricks.com"
  account_id    = var.databricks_account_id
  client_id     = var.databricks_client_id
  client_secret = var.databricks_client_secret
}

# 워크스페이스 레벨 (워크스페이스 생성 후 사용)
provider "databricks" {
  alias         = "workspace"
  host          = databricks_mws_workspaces.this.workspace_url
  client_id     = var.databricks_client_id
  client_secret = var.databricks_client_secret
}
