# =====================================================================
# Metastore owner / Workspace admin 그룹 자동 구성
# =====================================================================
# 설치 직후에는 metastore admin / workspace admin에 배포용 SP만 들어 있고
# 실제 사용자는 비어 있어 수동 지정이 필요합니다. 이 파일은 tfvars로 받은
# 그룹 이름과 이메일 목록을 사용해 다음을 자동화합니다.
#   - 그룹을 새로 생성 (이름에 local.suffix_us 가 붙어 재설치 시 충돌하지 않음)
#   - 지정한 이메일의 Account 사용자를 조회해 해당 그룹에 추가
#   - metastore owner 그룹 → metastore owner(=metastore admin)로 매핑
#   - workspace admin 그룹 → 워크스페이스 ADMIN 권한으로 매핑
#
# ⚠️ destroy 안전성 (중요)
# 여기서 다루는 principal(사용자/그룹)은 **워크스페이스가 아니라 Databricks Account
# 전체에 속한 계정 오브젝트**입니다. 즉 이 파일이 Terraform으로 "소유"하는 principal은
# destroy 시 Account에서 사라지고, 그 영향은 이 설치가 만든 워크스페이스뿐 아니라
# 같은 Account의 모든 워크스페이스에 미칩니다.
#
# 특히 databricks_user 를 account-level provider(databricks.mws)로 관리하면
# destroy 시 provider가 SCIM PATCH active=false 를 보내 **계정 사용자를 비활성화**합니다
# (provider 기본값: account-level이면 disable_as_user_deletion=true).
# 그러면 그 사용자는 Account 콘솔/모든 워크스페이스 로그인에서
# "Your user account has not been registered." 로 막힙니다.
#
# 그래서 기본 동작을 다음과 같이 잡습니다.
#   - 사용자: resource가 아니라 data source로 **조회만** 합니다(create_admin_users=false).
#     → destroy가 계정 사용자를 절대 건드리지 않습니다. apply/destroy를 반복해도 안전.
#   - 그룹: force=false 가 기본입니다(adopt_existing_admin_groups=false).
#     → Account에 같은 이름 그룹이 이미 있으면 채택하지 않고 apply가 실패합니다.
#       채택했다면 destroy가 "내가 만들지 않은 공용 그룹"을 지워버리기 때문입니다.

locals {
  # 그룹 이름이 지정된 경우에만 해당 그룹을 관리합니다(빈 값이면 비활성).
  manage_metastore_owner_group = var.metastore_owner_group != ""
  manage_workspace_admin_group = var.workspace_admin_group != ""

  # 그룹 멤버로 넣을 전체 이메일(두 그룹 멤버 합집합, 중복 제거).
  all_admin_members = toset(concat(
    var.metastore_owner_members,
    var.workspace_admin_members,
  ))

  # 이메일 → Account user ID. 조회 모드/생성 모드 중 실제로 쓰인 쪽에서 가져옵니다.
  admin_user_ids = var.create_admin_users ? {
    for email, u in databricks_user.admin : email => u.id
    } : {
    for email, u in data.databricks_user.admin : email => u.id
  }

  # 그룹 이름에도 다른 리소스와 같은 랜덤 suffix를 붙입니다(언더스코어 버전).
  # 이유: 그룹은 Account 전역 네임스페이스입니다. suffix가 없으면
  #   (1) 같은 Account에 두 번 설치할 때 "group already exists"로 충돌하고
  #   (2) destroy 직후 재apply할 때 Account 측 삭제 전파가 늦으면 같은 충돌이 납니다.
  # suffix가 붙으면 매 설치가 자기만의 그룹을 만들고 자기 것만 지우므로
  # apply/destroy를 반복해도 서로 간섭하지 않습니다.
  metastore_owner_group = "${var.metastore_owner_group}${local.suffix_us}"
  workspace_admin_group = "${var.workspace_admin_group}${local.suffix_us}"
}

# [기본 경로] 이미 Account에 있는 사용자를 조회만 합니다.
# data source이므로 destroy 시 아무 것도 삭제/비활성화하지 않습니다.
# 사내 Account나 IdP(SCIM) 연동 Account에서는 사용자가 이미 존재하므로 이 경로가 맞습니다.
# 없는 이메일을 넣으면 "cannot find user <email>" 로 apply가 실패합니다.
data "databricks_user" "admin" {
  provider  = databricks.mws
  for_each  = var.create_admin_users ? toset([]) : local.all_admin_members
  user_name = each.value
}

# [옵션 경로] Account에 사용자가 아예 없어서 Terraform이 만들어야 하는 경우.
# force=false: 이미 존재하는 사용자를 채택하지 않습니다 → 이 resource는
#   "Terraform이 직접 만든 사용자"만 소유하게 되고, destroy가 남의 계정을 건드릴 수 없습니다.
# disable_as_user_deletion=false: 비활성화가 아니라 삭제 → apply/destroy 반복이 멱등해집니다
#   (비활성화만 하면 다음 apply의 create가 "already exists"로 실패).
resource "databricks_user" "admin" {
  provider                 = databricks.mws
  for_each                 = var.create_admin_users ? local.all_admin_members : toset([])
  user_name                = each.value
  force                    = false
  disable_as_user_deletion = false
}

# Metastore owner 그룹.
# force=true 로 켜면 Account의 동명 그룹을 채택하지만, destroy가 그 그룹을 삭제합니다.
resource "databricks_group" "metastore_owner" {
  count        = local.manage_metastore_owner_group ? 1 : 0
  provider     = databricks.mws
  display_name = local.metastore_owner_group
  force        = var.adopt_existing_admin_groups
}

# Workspace admin 그룹.
resource "databricks_group" "workspace_admin" {
  count        = local.manage_workspace_admin_group ? 1 : 0
  provider     = databricks.mws
  display_name = local.workspace_admin_group
  force        = var.adopt_existing_admin_groups
}

# Metastore owner 그룹 멤버십.
# 나열된 이메일만 그룹에 추가하며, 그룹에 이미 있던 다른 멤버는 건드리지 않습니다.
# destroy 시에는 멤버십(그룹↔사용자 연결)만 끊고 사용자 자체는 남습니다.
resource "databricks_group_member" "metastore_owner" {
  provider  = databricks.mws
  for_each  = local.manage_metastore_owner_group ? toset(var.metastore_owner_members) : toset([])
  group_id  = databricks_group.metastore_owner[0].id
  member_id = local.admin_user_ids[each.value]
}

# Workspace admin 그룹 멤버십.
resource "databricks_group_member" "workspace_admin" {
  provider  = databricks.mws
  for_each  = local.manage_workspace_admin_group ? toset(var.workspace_admin_members) : toset([])
  group_id  = databricks_group.workspace_admin[0].id
  member_id = local.admin_user_ids[each.value]
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
    metastore_owner_group   = local.manage_metastore_owner_group ? local.metastore_owner_group : "(미설정)"
    metastore_owner_members = var.metastore_owner_members
    workspace_admin_group   = local.manage_workspace_admin_group ? local.workspace_admin_group : "(미설정)"
    workspace_admin_members = var.workspace_admin_members
    # destroy가 계정 사용자를 건드리는지 여부를 한눈에 확인하는 용도.
    user_mode  = var.create_admin_users ? "생성/삭제(Terraform 소유 — destroy 시 사용자 삭제됨)" : "조회만(destroy가 계정 사용자를 건드리지 않음)"
    group_mode = var.adopt_existing_admin_groups ? "기존 그룹 채택(destroy 시 그룹 삭제됨 — 공용 그룹 주의)" : "신규 생성만(동명 그룹 있으면 apply 실패)"
  }
}
