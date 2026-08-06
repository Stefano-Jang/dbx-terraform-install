# storage_root 없이 metastore 생성 (catalog 별 스토리지 사용)
# existing_metastore_id가 지정되면(count=0) 생성하지 않고 기존 것을 재활용합니다.
# UC는 "리전당 metastore 1개" 제한이 있어, 같은 리전에 이미 있으면 재활용해야 합니다.
resource "databricks_metastore" "this" {
  count    = local.create_metastore ? 1 : 0
  provider = databricks.mws
  name     = "${local.prefix}-metastore"
  region   = var.region
  # metastore owner = metastore admin. 우선순위:
  #   1) metastore_owner_group 지정 시 → 해당 그룹(admin_groups.tf에서 생성)
  #   2) 아니면 unity_admin_group (하위 호환)
  #   3) 둘 다 비었으면 owner 생략 → metastore를 만든 SP가 자동으로 owner
  # owner는 Account에 실존하는 그룹/사용자/SP여야 합니다. metastore_owner_group을
  # 쓰면 databricks_group.metastore_owner 가 먼저 생성되므로 안전합니다.
  owner = local.manage_metastore_owner_group ? (
    databricks_group.metastore_owner[0].display_name
  ) : (var.unity_admin_group != "" ? var.unity_admin_group : null)
  force_destroy = true

  # 그룹이 먼저 존재해야 owner로 지정 가능
  depends_on = [databricks_group.metastore_owner]
}

# 워크스페이스에 metastore 할당 (신규/기존 여부와 무관하게 local.metastore_id 사용)
resource "databricks_metastore_assignment" "this" {
  provider     = databricks.mws
  metastore_id = local.metastore_id
  workspace_id = databricks_mws_workspaces.this.workspace_id

  # 배포 SP가 metastore owner 그룹 멤버로 추가된 뒤에 할당 → 이후 workspace-scope
  # UC 리소스(credential/location/catalog)를 SP가 admin 권한으로 생성할 수 있게 함.
  depends_on = [databricks_group_member.metastore_owner_deployer]

  lifecycle {
    # 기존 metastore를 재활용하는데 suffix가 꺼져 있으면, storage credential /
    # external location / catalog 이름이 그 metastore 안에서 다른 SA와 충돌할 수 있음.
    # 이 조합을 apply 전에 차단.
    precondition {
      condition = local.create_metastore || var.enable_random_suffix
      error_message = join(" ", [
        "기존 metastore 재활용(existing_metastore_id 지정) 시에는",
        "enable_random_suffix=true 여야 합니다.",
        "(suffix가 없으면 storage credential / external location / catalog 이름이",
        "공유 metastore 안에서 다른 SA와 충돌합니다.)",
        "정해진 이름을 반드시 써야 하면 uc_catalog_name 등을 SA별로 고유하게 지정하세요."
      ])
    }
  }
}

# metastore 재할당 후, workspace-scope UC API가 "새로 할당된 metastore"를 인식하기까지
# 계정 측 라우팅 전파에 시간이 걸립니다. 이 대기가 없으면 credential/external location/
# catalog가 워크스페이스 생성 직후 자동 연결됐던 "리전 기본 metastore"에 잘못 생성되어,
# 이후 우리 metastore로 재할당돼도 카탈로그가 워크스페이스 목록에서 사라집니다(레이스).
# uc_catalog.tf의 워크스페이스-스코프 리소스는 이 sleep에 의존합니다.
resource "time_sleep" "metastore_assignment_propagation" {
  depends_on      = [databricks_metastore_assignment.this]
  create_duration = var.metastore_assignment_propagation
}
