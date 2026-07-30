variable "aws_profile" {
  type    = string
  default = "aws-rnd-root"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "prefix" {
  type        = string
  default     = "rnd-root-dbx"
  description = "리소스 이름 접두어"
}

# 여러 SA가 같은 tfvars(같은 prefix/버킷명)를 재활용해도 이름이 충돌하지 않도록
# prefix와 UC 버킷명 뒤에 랜덤 suffix(-xxxxxx)를 자동으로 붙입니다.
# 고객 환경에 "정해진 이름 그대로" 설치해야 하면 false로 두세요.
variable "enable_random_suffix" {
  type        = bool
  default     = true
  description = "true면 prefix/uc_catalog_bucket_name 뒤에 -{random} suffix를 붙여 이름 충돌을 방지"
}

variable "random_suffix_length" {
  type        = number
  default     = 6
  description = "enable_random_suffix=true일 때 붙는 랜덤 suffix 길이"
}

# workspace URL 도메인 prefix(deployment_name)를 local.prefix로 고정할지 여부.
# true로 켜려면 Databricks Account에 "deployment name prefix"가 미리 등록돼 있어야 합니다.
# false(기본)면 Databricks가 dbc-xxxxxxxx 형태로 URL을 자동 발급합니다.
variable "set_deployment_name" {
  type        = bool
  default     = false
  description = "workspace URL 도메인을 local.prefix로 지정할지 여부(Account에 deployment name prefix 등록 필요)"
}

variable "databricks_account_id" {
  type      = string
  sensitive = true
}

variable "databricks_client_id" {
  type      = string
  sensitive = true
}

variable "databricks_client_secret" {
  type      = string
  sensitive = true
}

variable "cidr_block" {
  type    = string
  default = "10.10.0.0/16"
}

variable "tags" {
  type = map(string)
  default = {
    Project = "databricks-rnd-root"
    Owner   = "platform-team"
  }
}

# Unity Catalog Managed Default Catalog의 root bucket 이름
variable "uc_catalog_bucket_name" {
  type        = string
  description = "UC managed default catalog의 root S3 버킷 이름 (전역 고유)"
  default     = "rnd-root-dbx-uc-catalog-root"
}

# Unity Catalog Managed Default Catalog의 이름 (metastore 내 고유)
# 하이픈(-)은 백틱 처리가 필요하므로 언더스코어(_)만 사용하세요.
variable "uc_catalog_name" {
  type        = string
  description = "UC managed default catalog 이름 (언더스코어 사용 권장)"
  default     = "main_rnd_root"
}

variable "unity_admin_group" {
  type = string
  # metastore owner로 지정할 Account 그룹/사용자/SP. 반드시 Account에 실존해야 합니다.
  # 빈 값이면 owner를 생략 → metastore를 만든 principal(SP)이 자동으로 owner가 됩니다.
  # 기본 그룹 "account_unity_admin"은 모든 Account에 있는 게 아니므로 기본값을 빈 값으로 둡니다.
  default     = ""
  description = "UC metastore owner 그룹/사용자(비우면 생성 SP가 owner)"
}

# 기존 metastore 재활용:
# UC는 "리전당 metastore 1개" 제한이 있으므로, 같은 리전에 이미 metastore가 있으면
# 새로 만들 수 없습니다. 그 경우 기존 metastore ID를 여기에 지정하면
# 새로 생성하지 않고 해당 metastore를 워크스페이스에 할당만 합니다.
#   - "" (빈 값, 기본): 새 metastore 생성
#   - "<metastore-uuid>": 기존 metastore 재활용
# 기존 metastore ID 확인: databricks account metastores list
variable "existing_metastore_id" {
  type        = string
  default     = ""
  description = "재활용할 기존 metastore ID. 빈 값이면 새로 생성"
}

# ----------------------------------------------------------------------
# Metastore / Workspace admin 그룹 자동 구성
# ----------------------------------------------------------------------
# 설치 후 metastore admin / workspace admin에는 배포 SP만 들어 있으므로,
# 아래 값으로 admin 그룹과 사용자를 자동 구성합니다(admin_groups.tf).
#   - 그룹 이름이 Account에 이미 있으면 채택, 없으면 새로 생성
#   - members의 이메일이 없으면 사용자 생성 후 그룹에 추가(force=true)
# 그룹 이름을 빈 값("")으로 두면 해당 그룹 자동 구성을 건너뜁니다.

variable "metastore_owner_group" {
  type        = string
  default     = ""
  description = "metastore owner(=metastore admin)로 지정할 Account 그룹 이름. 빈 값이면 미구성"
}

variable "metastore_owner_members" {
  type        = list(string)
  default     = []
  description = "metastore owner 그룹에 넣을 이메일 목록(없으면 사용자 생성 후 추가)"
}

variable "workspace_admin_group" {
  type        = string
  default     = ""
  description = "workspace admin(ADMIN 권한)으로 지정할 Account 그룹 이름. 빈 값이면 미구성"
}

variable "workspace_admin_members" {
  type        = list(string)
  default     = []
  description = "workspace admin 그룹에 넣을 이메일 목록(없으면 사용자 생성 후 추가)"
}

# metastore_assignment 후 workspace-scope UC API가 "새로 할당된 metastore"를 인식하기까지의
# 전파 대기 시간. 이 대기가 없으면 워크스페이스 생성 직후 UC가 자동 연결한 "리전 기본
# metastore"에 catalog/credential/external location이 잘못 생성되어(레이스), 이후 우리가
# 만든 metastore로 재할당돼도 카탈로그가 워크스페이스 목록에서 사라집니다.
variable "metastore_assignment_propagation" {
  type        = string
  default     = "60s"
  description = "metastore 재할당 후 workspace UC 라우팅 전파를 기다리는 시간(예: 60s, 90s)"
}

# Zerobus Ingest용 "service-direct" 사설 인입(inbound) PrivateLink.
# 기본 off. Zerobus를 사설로 쓸 때 true로 켜면 3.7의 리소스가 생성됨.
variable "enable_zerobus_privatelink" {
  type        = bool
  default     = false
  description = "Zerobus Ingest용 service-direct 인입 PrivateLink 엔드포인트 생성 여부"
}
