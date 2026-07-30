resource "databricks_mws_private_access_settings" "pas" {
  provider                     = databricks.mws
  private_access_settings_name = "${local.prefix}-pas"
  region                       = var.region

  # backend 전용 PrivateLink: 프론트엔드(웹UI)는 여전히 public 허용
  #   public_access_enabled = true
  # 완전 사설(frontend PrivateLink까지)로 잠그려면 false
  public_access_enabled = true

  # true = 등록된 VPC Endpoint만 허용 (권장, backend 강제)
  private_access_level = "ACCOUNT"
}
