# =====================================================================
# Metastore owner / Workspace admin 그룹 자동 구성
# =====================================================================
# 설치 직후에는 metastore admin / workspace admin에 배포용 SP만 들어 있고
# 실제 사용자는 비어 있어 수동 지정이 필요합니다. 이 파일은 tfvars로 받은
# 그룹 이름과 이메일 목록을 사용해 다음을 자동화합니다.
#   - Account에 해당 그룹이 이미 있으면 그대로 채택(adopt)하고, 없으면 새로 생성
#   - 지정한 이메일 사용자를 (없으면 생성 후) 해당 그룹에 추가
#   - metastore owner 그룹 → metastore owner(=metastore admin)로 매핑
#   - workspace admin 그룹 → 워크스페이스 ADMIN 권한으로 매핑
#
# 핵심은 databricks_group / databricks_user 의 force=true 입니다.
#   force=true 면 같은 이름/이메일의 principal이 Account에 이미 존재할 때
#   에러 없이 채택(adopt)하므로 "있으면 재활용, 없으면 생성"이 그대로 동작합니다.

locals {
  # 그룹 이름이 지정된 경우에만 해당 그룹을 관리합니다(빈 값이면 비활성).
  manage_metastore_owner_group = var.metastore_owner_group != ""
  manage_workspace_admin_group = var.workspace_admin_group != ""

  # databricks_user로 생성/채택할 전체 이메일(두 그룹 멤버 합집합, 중복 제거).
  all_admin_members = toset(concat(
    var.metastore_owner_members,
    var.workspace_admin_members,
  ))
}

# 관리 대상 이메일의 Account 사용자.
# force=true: 이미 Account에 있으면 새로 만들지 않고 채택, 없으면 생성.
resource "databricks_user" "admin" {
  provider  = databricks.mws
  for_each  = local.all_admin_members
  user_name = each.value
  force     = true
}

# Metastore owner 그룹.
# force=true: Account에 같은 이름 그룹이 있으면 채택, 없으면 생성.
resource "databricks_group" "metastore_owner" {
  count        = local.manage_metastore_owner_group ? 1 : 0
  provider     = databricks.mws
  display_name = var.metastore_owner_group
  force        = true
}

# Workspace admin 그룹.
resource "databricks_group" "workspace_admin" {
  count        = local.manage_workspace_admin_group ? 1 : 0
  provider     = databricks.mws
  display_name = var.workspace_admin_group
  force        = true
}

# Metastore owner 그룹 멤버십.
# 나열된 이메일만 그룹에 추가하며, 그룹에 이미 있던 다른 멤버는 건드리지 않습니다.
resource "databricks_group_member" "metastore_owner" {
  provider  = databricks.mws
  for_each  = local.manage_metastore_owner_group ? toset(var.metastore_owner_members) : toset([])
  group_id  = databricks_group.metastore_owner[0].id
  member_id = databricks_user.admin[each.value].id
}

# Workspace admin 그룹 멤버십.
resource "databricks_group_member" "workspace_admin" {
  provider  = databricks.mws
  for_each  = local.manage_workspace_admin_group ? toset(var.workspace_admin_members) : toset([])
  group_id  = databricks_group.workspace_admin[0].id
  member_id = databricks_user.admin[each.value].id
}

# 배포용 SP(=이 Terraform을 실행하는 principal).
# metastore owner를 그룹으로 넘기면, 이 SP가 metastore admin이 아니게 되어
# storage credential / external location / catalog 생성이 PERMISSION_DENIED로 실패합니다.
# 그래서 SP를 owner 그룹의 멤버로 넣어 admin 권한을 유지시킵니다.
data "databricks_service_principal" "deployer" {
  count          = local.manage_metastore_owner_group ? 1 : 0
  provider       = databricks.mws
  application_id = var.databricks_client_id
}

# 배포 SP를 metastore owner 그룹에 추가 → SP가 metastore admin 권한 유지.
resource "databricks_group_member" "metastore_owner_deployer" {
  count     = local.manage_metastore_owner_group ? 1 : 0
  provider  = databricks.mws
  group_id  = databricks_group.metastore_owner[0].id
  member_id = data.databricks_service_principal.deployer[0].sp_id
}

# Workspace admin 그룹을 워크스페이스에 ADMIN 권한으로 할당.
# (metastore owner 매핑은 uc_metastore.tf 의 owner 로 처리)
resource "databricks_mws_permission_assignment" "workspace_admin" {
  count        = local.manage_workspace_admin_group ? 1 : 0
  provider     = databricks.mws
  workspace_id = databricks_mws_workspaces.this.workspace_id
  principal_id = databricks_group.workspace_admin[0].id
  permissions  = ["ADMIN"]
}

output "admin_groups" {
  value = {
    metastore_owner_group   = local.manage_metastore_owner_group ? var.metastore_owner_group : "(미설정)"
    metastore_owner_members = var.metastore_owner_members
    workspace_admin_group   = local.manage_workspace_admin_group ? var.workspace_admin_group : "(미설정)"
    workspace_admin_members = var.workspace_admin_members
  }
}
