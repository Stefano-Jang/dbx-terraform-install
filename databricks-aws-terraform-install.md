# Terraform으로 AWS(`aws-rnd-root`)에 Databricks 설치하기 — Step-by-Step 가이드

이 문서는 **Terraform**을 사용해 AWS 계정 `aws-rnd-root`에 Databricks E2 워크스페이스를
프로비저닝하는 전체 과정을 **명령어 수준**으로 정리한 실습 가이드입니다.

포함 범위:

1. AWS / Databricks Account 사전 준비
2. 네트워크(VPC, 서브넷, 보안그룹) 구성
3. **Backend PrivateLink**(REST API + Relay(SCC)) 완전 구성
4. Cross-account IAM Role · Root S3 Bucket · Storage 구성
5. 워크스페이스 생성(Private Access Settings 포함)
6. **Unity Catalog Metastore + Managed Default Catalog의 Root Bucket 위치 지정**
7. 검증 및 트러블슈팅

> ⚠️ 이 가이드는 **backend(전용) PrivateLink** 시나리오를 기준으로 합니다.
> - Backend PrivateLink: 데이터 플레인(클러스터) → 컨트롤 플레인(REST API + Relay) 사설 연결
> - Frontend PrivateLink(사용자 → 워크스페이스)는 선택 사항이며 마지막에 옵션으로 설명합니다.

---

## 0. 사전 요구 사항 (Prerequisites)

### 0.1 도구 설치

```bash
# Terraform (1.5+ 권장)
terraform -version
# 없으면 (macOS)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# AWS CLI v2
aws --version
brew install awscli   # 없으면

# Databricks CLI (검증용, 선택)
brew tap databricks/tap
brew install databricks
```

#### 0.1.1 이미 설치되어 있는 경우 — 최신 버전으로 업데이트

이미 Terraform / AWS CLI / Databricks CLI가 설치되어 있다면, 아래로 **현재 버전 확인 후 최신으로 업데이트**하세요.

```bash
# 0) 현재 설치된 버전 먼저 확인
terraform -version      # 예: Terraform v1.9.0
aws --version           # 예: aws-cli/2.15.0 Python/3.11 ...
databricks -v           # 예: Databricks CLI v0.230.0
```

```bash
# 1) Homebrew 자체 및 formula 정보 최신화 (업데이트 전 항상 권장)
brew update

# 2) Terraform 업데이트
#    ⚠️ tfenv로 관리 중이면 brew가 아니라 tfenv를 사용 → 0.1.2 참고
brew upgrade hashicorp/tap/terraform

# 3) AWS CLI v2 업데이트
brew upgrade awscli

# 4) Databricks CLI 업데이트
brew upgrade databricks

# 5) 특정 도구만이 아니라 설치된 전체 패키지를 한 번에 업데이트하려면
brew upgrade            # 모든 outdated formula 업그레이드

# 6) 업데이트 후 버전 재확인
terraform -version
aws --version
databricks -v
```

> 💡 **팁**
> - `brew outdated` 로 업그레이드 대상이 있는지 미리 확인할 수 있습니다.
> - `brew upgrade <name>` 이 "already installed"라고만 나오면 이미 최신입니다.
> - Homebrew로 설치하지 않은 경우(수동 설치/공식 스크립트):
>   - **AWS CLI v2 (macOS pkg 재설치로 업데이트)**:
>     ```bash
>     curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
>     sudo installer -pkg AWSCLIV2.pkg -target /
>     ```
>   - **Databricks CLI (공식 설치 스크립트, 재실행 시 최신으로 교체)**:
>     ```bash
>     curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
>     ```
>   - **Terraform**: 공식 바이너리를 직접 받았다면 새 버전 바이너리로 교체하거나
>     아래 tfenv 워크플로로 전환하는 것을 권장합니다.

#### 0.1.2 Terraform이 tfenv로 관리되는 경우

로컬에서 여러 Terraform 버전을 오가야 하거나, 팀/프로젝트별로 버전을 고정하려면
**[tfenv](https://github.com/tfutils/tfenv)** (Terraform 버전 관리자)를 사용하는 것이 편리합니다.
이 경우 `terraform` 바이너리는 tfenv가 심는 심볼릭 링크이므로,
`brew upgrade terraform`이 아니라 **tfenv 명령으로 버전을 관리**해야 합니다.

```bash
# 현재 terraform이 tfenv로 관리되는지 확인
which terraform                 # 예: /opt/homebrew/bin/terraform
readlink $(which terraform)     # ../Cellar/tfenv/<ver>/bin/terraform 이면 tfenv 관리
# → 위처럼 tfenv 경로가 보이면 아래 tfenv 워크플로를 사용

# tfenv 설치 (아직 없다면)
brew install tfenv
```

tfenv로 설치·전환·고정하기:

```bash
# 설치 가능한 버전 목록 (최신 안정 버전 확인)
tfenv list-remote | head        # alpha/beta/rc를 제외한 최상단 x.y.z가 최신 안정 버전
# 특정 안정 버전 설치 (예: 1.15.8)
tfenv install 1.15.8
# 최신 안정 버전을 자동으로 설치하려면
tfenv install latest

# 기본으로 사용할 버전 전환
tfenv use 1.15.8

# 설치된 버전 목록 (*가 현재 활성 버전)
tfenv list
```

> ⚠️ **주의사항**
> - tfenv는 `alpha`/`beta`/`rc` 프리릴리스도 함께 나열합니다. 운영에는 반드시
>   **프리릴리스가 아닌 최신 `x.y.z` 안정 버전**을 사용하세요.
> - tfenv로 관리 중일 때 `brew upgrade`로 terraform을 올리려 하면 심볼릭 링크와
>   충돌하거나 실제 사용 버전이 바뀌지 않을 수 있습니다. **버전 변경은 tfenv로만** 하세요.
> - 프로젝트 디렉터리에 **`.terraform-version`** 파일(예: 내용이 `1.15.8`)을 두면,
>   해당 디렉터리에서 tfenv가 자동으로 그 버전을 선택합니다. 팀원 간 버전 고정에 유용합니다.

```bash
# (권장) 이 프로젝트에서 사용할 Terraform 버전을 고정
cd /Users/stefano.jang/workspace/dbx-terraform-install
echo "1.15.8" > databricks-aws/.terraform-version   # 디렉터리 진입 시 자동 적용
```

### 0.2 필수 계정/권한

| 항목 | 설명 |
|------|------|
| **Databricks Account** | E2 플랫폼, **Databricks Account ID** 필요 (accounts.cloud.databricks.com → 우상단 프로필) |
| **Account Admin** | 워크스페이스/메타스토어 생성 권한 |
| **AWS 계정 `aws-rnd-root`** | VPC, IAM, S3, VPC Endpoint, Route53 생성 권한. **설치용 profile에는 `AdministratorAccess` 관리형 정책 권장**(부록 D에 최소 권한 정리) |
| **Databricks 지원 리전** | 예: `us-west-2`, `ap-northeast-2`(서울) 등 |
| **PrivateLink 활성화** | Databricks Account에서 PrivateLink 지원 필요(Enterprise 티어). 미지원 시 Databricks 담당자에게 활성화 요청 |

### 0.2.1 어떤 Databricks Account에 만들 것인가 (중요 개념 정리)

> ✅ **결론 먼저**: 이미 `stefano.jang@databricks.com`으로 Databricks에 가입되어 있어도
> **새 이메일로 재가입할 필요가 없습니다.** 이 가이드가 Terraform으로 만드는 것은
> "새로운 Databricks Account"가 아니라 **기존 Account 안에 격리된 새 워크스페이스**
> (+ 네트워크 / 스토리지 / 메타스토어)이기 때문입니다.

**Account 와 Workspace 는 다른 개념입니다.**

| 개념 | 의미 | 이 가이드에서 |
|------|------|--------------|
| **Account** | `accounts.cloud.databricks.com`에 붙는 최상위 조직 단위. 여러 워크스페이스를 담는 컨테이너 | **기존 것을 재사용** (신규 생성 대상 아님) |
| **User / Identity** | `stefano.jang@databricks.com` 같은 로그인 신원 | 이미 가입되어 있어도 **문제 없음** |
| **Workspace** | `databricks_mws_workspaces`로 만드는 실제 작업 환경 | **Terraform이 새로 생성** (완전 격리) |

하나의 Account는 **여러 워크스페이스**를 담을 수 있고, 각 워크스페이스는 서로 다른
네트워크·스토리지·카탈로그를 가진 **독립 환경**입니다. 따라서 "이미 가입되어 있어서
새 환경을 못 만든다"는 것은 사실이 아닙니다.

**❌ 새 이메일로 self sign-up 하는 것은 권장하지 않습니다:**

1. 신규 셀프 가입 계정은 기본 tier가 낮아, 이 가이드의 PrivateLink에 필요한
   **`ENTERPRISE` tier가 없을 수 있습니다** (5장 `pricing_tier = "ENTERPRISE"` 참고).
2. 개인/신규 이메일 계정으로 **회사 AWS(`aws-rnd-root`)** 인프라를 프로비저닝하는 것은
   거버넌스/정책상 부적절합니다.
3. 메타스토어는 **리전당 계정별 1개** 제한이 있어(부록 A), 어떤 Account를 쓰는지가 실제로 중요합니다.

**✅ 권장 방식 — 사내 테스트 Account 재사용:**

Databricks 사내에는 `sandbox`, `dogfood`, `e2demo` 등 **테스트용 Account 프로파일**이
이미 준비되어 있습니다. 프로덕션 회사 계정을 오염시키지 않도록, 이런 **사내 테스트
Account에 새 워크스페이스를 생성**하세요. 새 이메일은 필요 없습니다.

```bash
# 사내에서 사용 가능한 Databricks Account 프로파일 확인 (.databrickscfg)
databricks auth profiles

# 대상 Account에 로그인 (예: sandbox) — Account 콘솔 host 사용
databricks auth login --host https://accounts.cloud.databricks.com --profile sandbox

# 로그인한 Account에서 대상 Account ID 확인 (아래 0.3에서 사용할 값)
databricks account get --profile sandbox 2>/dev/null || \
  echo "→ accounts.cloud.databricks.com 우상단 프로필에서 Account ID 확인"
```

> ⚠️ **주의**
> - 어떤 Account/프로파일을 쓸지는 **직접 선택**하고, 프로덕션 계정은 피하세요.
> - 이 가이드의 뒷부분에서 사용하는 `DATABRICKS_ACCOUNT_ID` 는 **당신이 선택한
>   테스트 Account 의 ID** 여야 합니다.
> - PrivateLink/`ENTERPRISE` tier 가 해당 테스트 Account 에서 활성화되어 있는지
>   확인하고, 없으면 Account 담당자에게 요청하세요.

### 0.3 Databricks Account 인증용 OAuth Service Principal 발급

Account 레벨 리소스(`databricks_mws_*`, `databricks_metastore`)를 만들려면
**Account 레벨 OAuth Service Principal**이 필요합니다.

> 📌 아래 절차는 **0.2.1에서 선택한 테스트 Account**(예: `sandbox`)에서 수행하세요.
> 로그인한 사용자가 그 Account의 **Account admin** 이어야 SP 생성/권한 부여가 가능합니다.

1. https://accounts.cloud.databricks.com → **User management → Service principals → Add service principal**
2. 생성된 SP를 **Account admin** 역할로 추가
3. SP에서 **OAuth secret** 생성 → `Client ID`, `Client Secret` 저장

```bash
# 발급받은 값을 환경변수로 export (뒤에서 Terraform이 사용)
export DATABRICKS_ACCOUNT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export DATABRICKS_CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export DATABRICKS_CLIENT_SECRET="dose_xxxxxxxxxxxxxxxxxxxx"
```

### 0.4 AWS `aws-rnd-root` 인증 프로파일 설정

> 🔑 **이 profile에 필요한 권한** — 이 Terraform은 VPC/서브넷/NAT/보안그룹, IAM Role·정책,
> S3 버킷·정책, VPC Endpoint(PrivateLink), Route53(Zerobus 옵션 시)을 **생성·수정·삭제**합니다.
> 부트스트랩 단계에서 권한 부족으로 apply가 중간에 멈추는 것을 피하려면, 설치용 profile에
> **`AdministratorAccess` 관리형 정책**을 붙이는 것을 권장합니다.
> 조직 정책상 최소 권한이 필요하면 **부록 D**의 서비스별 권한 목록을 참고하세요.
> (특히 `iam:CreateRole`·`iam:PassRole`이 SCP/permission boundary에 막히면 설치가 실패합니다.)

> ⚠️ **먼저 회사 브라우저로 SSO 로그인부터** — `aws configure sso`가 열어 주는
> 인증 페이지는 **회사 IdP(SSO) 세션이 이미 있어야** 자동으로 인증됩니다.
> 명령을 실행하기 **전에** 회사 브라우저에서 **`go/aws-rnd-root`** 로 먼저 로그인해
> SSO 세션을 만들어 두세요. (세션이 없으면 브라우저 승인 단계에서 막히거나
> `aws sts get-caller-identity`가 `token has expired` / 인증 실패로 떨어집니다.)

```bash
# 0) (선행) 회사 브라우저에서 go/aws-rnd-root 로 먼저 로그인해 SSO 세션 생성
#    → 브라우저에 aws-rnd-root SSO 세션이 살아있는 상태에서 아래를 실행

# SSO 사용 시
aws configure sso --profile aws-rnd-root
#   실행하면 브라우저 승인 창이 열립니다. 위에서 만든 SSO 세션이 있으면
#   자동으로 통과되고, 없으면 로그인부터 다시 요구됩니다.

# 또는 액세스 키 사용 시
aws configure --profile aws-rnd-root

# 확인: 올바른 계정에 붙었는지 반드시 검증
aws sts get-caller-identity --profile aws-rnd-root
```

> 💡 SSO 세션은 만료됩니다. 나중에 `token has expired` 오류가 나면 다시
> `go/aws-rnd-root` 로 로그인하거나 **`aws sso login --profile aws-rnd-root`** 로
> 세션만 갱신하면 됩니다(프로파일 재구성 불필요).

출력의 `Account` 값이 `aws-rnd-root` 계정 ID와 일치하는지 확인하세요.

```bash
export AWS_PROFILE=aws-rnd-root
export AWS_REGION=ap-northeast-2   # 예: 서울 리전
```

---

## 1. 프로젝트 디렉터리 및 Provider 구성

```bash
cd /Users/stefano.jang/workspace/dbx-terraform-install
mkdir -p databricks-aws && cd databricks-aws
```

### 1.1 `versions.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}
```

### 1.2 `providers.tf`

Databricks는 **두 개의 provider alias**를 사용합니다.
- `databricks.mws` : Account 레벨(워크스페이스·네트워크·메타스토어 생성)
- `databricks.workspace` : 생성된 워크스페이스 내부(카탈로그·권한 등) — 2단계에서 워크스페이스 생성 후 사용

```hcl
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
```

### 1.3 `variables.tf`

```hcl
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
  type    = map(string)
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

# Metastore owner / Workspace admin 그룹 자동 구성 (6.2.5 admin_groups.tf).
# 그룹 이름이 Account에 있으면 채택, 없으면 생성. members 이메일이 없으면 생성 후 그룹에 추가.
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

# metastore 재할당 후 workspace-scope UC API가 새 metastore를 인식하기까지의 전파 대기.
# 이 대기가 없으면 카탈로그가 워크스페이스 생성 직후 자동 연결된 "리전 기본 metastore"에
# 잘못 생성되어(레이스) 워크스페이스 목록에서 사라집니다(6.2 참고).
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
```

### 1.4 `locals.tf`

```hcl
# 이름 충돌 방지용 랜덤 suffix (enable_random_suffix=true 일 때만 의미 있음)
resource "random_string" "suffix" {
  length  = var.random_suffix_length
  special = false
  upper   = false
  numeric = true
}

locals {
  # enable_random_suffix=true  → "-xxxxxx"  (예: rnd-root-dbx-a1b2c3)
  # enable_random_suffix=false → ""         (tfvars에 넣은 이름 그대로)
  suffix = var.enable_random_suffix ? "-${random_string.suffix.result}" : ""

  # UC catalog 이름은 하이픈(-) 사용이 까다로워 언더스코어(_) suffix를 별도로 사용
  # enable_random_suffix=true  → "_xxxxxx"
  # enable_random_suffix=false → ""
  suffix_us = var.enable_random_suffix ? "_${random_string.suffix.result}" : ""

  # prefix에서 파생되는 모든 리소스 이름(workspace_name, IAM role, network,
  # credentials, storage config, deployment_name 등)에 suffix가 일괄 적용됩니다.
  prefix = "${var.prefix}${local.suffix}"

  # UC managed default catalog root 버킷 이름 (전역 고유해야 함)
  uc_catalog_bucket_name = "${var.uc_catalog_bucket_name}${local.suffix}"

  # UC managed default catalog 이름 (metastore 내 고유해야 함)
  uc_catalog_name = "${var.uc_catalog_name}${local.suffix_us}"

  # 기존 metastore 재활용 여부
  create_metastore = var.existing_metastore_id == ""
  # 실제로 사용할 metastore ID (새로 만들면 생성된 것, 아니면 기존 것)
  metastore_id = local.create_metastore ? databricks_metastore.this[0].id : var.existing_metastore_id

  # PrivateLink용 리전별 서비스 이름 (VPC Endpoint Service).
  # ⚠️ 아래는 예시이며 리전마다 다릅니다.
  # 리전별 workspace(REST API) / relay(SCC) VPC Endpoint Service 이름 표:
  # https://docs.databricks.com/aws/en/resources/ip-domain-region#privatelink-vpc-endpoint-services
  private_link = {
    # ap-northeast-2 (Seoul) 예시 - 배포 전 반드시 최신 값으로 교체
    # 표의 "General access (including REST API)" 값
    workspace_service = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0babb9bde64f34d7e"
    # 표의 "Secure cluster connectivity relay" 값
    relay_service     = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0dc0e98a5800db5c4"
    # 표의 "Inbound private link for performance-intensive services" 값
    #   (Zerobus Ingest 사설 인입용).
    #   기본 배포에는 미사용이며, var.enable_zerobus_privatelink=true 일 때만 3.7에서 사용.
    zerobus_service   = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0eda2860bd3ffdc62"
  }

  # Zerobus/service-direct 인입이 resolve해야 하는 리전별 DNS 호스트명
  # (private_dns_enabled 대신 Route53 private hosted zone으로 이 이름을 endpoint에 매핑)
  zerobus_dns_name = "${var.region}.service-direct.privatelink.cloud.databricks.com"
}
```

> 📌 **중요**: PrivateLink VPC Endpoint Service 이름은 리전별로 고정되어 있으며
> Databricks 공식 문서에서 최신 값을 확인해야 합니다. 위 값은 예시입니다.
> 리전별 endpoint service 이름 표(공식):
> https://docs.databricks.com/aws/en/resources/ip-domain-region#privatelink-vpc-endpoint-services

> #### 리전 표의 3가지 endpoint service — 무엇을 쓰고 무엇을 안 쓰나
>
> 위 리전별 표에는 리전마다 **3개의 VPC Endpoint Service**가 나열됩니다. 방향(direction)으로
> 구분하는 것이 핵심입니다:
>
> | 표의 카테고리 | 방향 | 용도 | 이 가이드 |
> |---|---|---|---|
> | **General access (including REST API)** | frontend + backend 공용 | 데이터플레인→REST API(backend) **및** 사용자→워크스페이스 웹/REST(frontend) | ✅ `workspace_service` |
> | **Secure cluster connectivity relay** | backend 전용 | 클러스터 ↔ 컨트롤플레인 보안 터널(SCC) | ✅ `relay_service` |
> | **Inbound private link for performance-intensive services** | inbound(frontend) 전용 | **Zerobus Ingest**(443)로의 사설 인입(service-direct) | ⚙️ 선택(기본 off, `var.enable_zerobus_privatelink`로 on) |
>
> **세 번째(performance-intensive)를 구성하지 않으면 무엇이 public 망을 타나?**
> - backend 경로(클러스터→REST API, 클러스터→SCC relay)는 이 구성으로 **이미 완전히 사설화**되어
>   영향이 없습니다.
> - public 망을 타는 것은 **Zerobus Ingest로의 인입(frontend) 연결**뿐입니다.
> - (참고) 이 가이드는 `pas.tf`에서 `public_access_enabled = true`로 두는 **backend 전용
>   시나리오**이므로, 사용자→워크스페이스 웹 UI 등 일반 frontend 트래픽도 public을 탑니다.
>   이를 사설화하려면 9장(Frontend PrivateLink) 옵션을 참고하세요.
> - Zerobus 사설 인입 구성 방법:
>   https://docs.databricks.com/aws/en/security/network/front-end/service-direct-privatelink
>
> 💡 **나중에 Zerobus를 쓸 계획이라면**: 이 엔드포인트는 처음부터 켤 수 있도록 스캐폴딩되어
> 있습니다. `var.enable_zerobus_privatelink = true`로 설정하면 **3.7 절**의 리소스가 함께
> 생성됩니다. 기본값은 `false`라 지금 배포에는 아무 영향이 없습니다.

### 1.5 `terraform.tfvars` (민감정보는 환경변수 권장)

```hcl
region                 = "ap-northeast-2"
prefix                 = "rnd-root-dbx"
cidr_block             = "10.10.0.0/16"
uc_catalog_bucket_name = "rnd-root-dbx-uc-catalog-root"
uc_catalog_name        = "main_rnd_root"   # UC 카탈로그 이름 (언더스코어 사용)

# 이름 충돌 방지용 랜덤 suffix.
#   true  (기본): prefix / uc_catalog_bucket_name 뒤에 -{random} 이 붙음 → 여러 SA 재활용 안전
#   false       : tfvars에 넣은 이름 그대로 설치 (고객 환경 등 "정해진 이름" 필요 시)
enable_random_suffix = true
# random_suffix_length = 6

# (선택) workspace URL 도메인을 prefix로 지정 (Account에 deployment name prefix 등록 필요)
# set_deployment_name = false

# (선택) 같은 리전에 이미 metastore가 있으면 기존 것을 재활용 (없으면 새로 생성)
#   확인: databricks account metastores list
# existing_metastore_id = "12a3b4c5-...."

# (선택) Metastore owner / Workspace admin 그룹 자동 구성 (6.2.5 참고)
#   그룹이 Account에 있으면 채택, 없으면 생성. 이메일이 없으면 사용자 생성 후 그룹에 추가.
#   그룹 이름을 비우면("") 해당 그룹 자동 구성을 건너뜁니다.
# metastore_owner_group   = "metastore_owners"
# metastore_owner_members = ["alice@example.com", "bob@example.com"]
# workspace_admin_group   = "workspace_admins"
# workspace_admin_members = ["alice@example.com", "carol@example.com"]

# (선택) Zerobus Ingest 사설 인입 PrivateLink를 켜려면 주석 해제 (기본 false)
# enable_zerobus_privatelink = true
```

민감 변수는 tfvars에 넣지 말고 환경변수로 주입:

```bash
export TF_VAR_databricks_account_id="$DATABRICKS_ACCOUNT_ID"
export TF_VAR_databricks_client_id="$DATABRICKS_CLIENT_ID"
export TF_VAR_databricks_client_secret="$DATABRICKS_CLIENT_SECRET"
```

---

## 2. 네트워크(VPC) 구성 — `network.tf`

Databricks customer-managed VPC 요구사항:
- **2개 이상의 프라이빗 서브넷**(서로 다른 AZ, 데이터 플레인 노드용)
- **PrivateLink용 별도 서브넷**(VPC Endpoint 배치)
- NAT Gateway(아웃바운드) 또는 완전 사설 구성

```hcl
# terraform-aws-modules/vpc 모듈 사용
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.prefix}-vpc"
  cidr = var.cidr_block

  azs = ["${var.region}a", "${var.region}c"]

  # 데이터 플레인(클러스터) 프라이빗 서브넷
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24"]
  # PrivateLink VPC Endpoint 전용 서브넷
  intra_subnets   = ["10.10.3.0/24", "10.10.4.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true

  tags = var.tags
}

# 데이터 플레인 보안그룹 (클러스터 노드용)
# Databricks 요구사항: 내부 통신 all-all, 아웃바운드 443/3306/6666/8443-8451
resource "aws_security_group" "dataplane" {
  vpc_id      = module.vpc.vpc_id
  name        = "${local.prefix}-dataplane-sg"
  description = "Databricks dataplane SG"

  # 그룹 내부 자기참조 (노드 간 통신)
  ingress {
    description = "internal-tcp"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }
  ingress {
    description = "internal-udp"
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    self        = true
  }

  egress {
    description = "internal-tcp"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }
  egress {
    description = "internal-udp"
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    self        = true
  }
  egress {
    description = "https"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "metastore-3306"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "scc-relay-6666"
    from_port   = 6666
    to_port     = 6666
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "future-8443-8451"
    from_port   = 8443
    to_port     = 8451
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# PrivateLink VPC Endpoint 전용 보안그룹 (443 인바운드 허용)
resource "aws_security_group" "vpce" {
  vpc_id      = module.vpc.vpc_id
  name        = "${local.prefix}-vpce-sg"
  description = "SG for Databricks PrivateLink VPC endpoints"

  ingress {
    description     = "https from dataplane"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.dataplane.id]
  }
  ingress {
    description     = "relay 6666 from dataplane"
    from_port       = 6666
    to_port         = 6666
    protocol        = "tcp"
    security_groups = [aws_security_group.dataplane.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}
```

---

## 3. Backend PrivateLink 구성 — `privatelink.tf`

Backend PrivateLink는 **두 개의 인터페이스 VPC Endpoint**로 구성됩니다:
1. **Workspace(REST API)** endpoint
2. **Relay(SCC — Secure Cluster Connectivity)** endpoint

각 AWS VPC Endpoint를 만든 뒤, Databricks Account에 **등록**(`databricks_mws_vpc_endpoint`)합니다.

```hcl
# 3.1 AWS VPC Endpoint - Workspace(REST API)
resource "aws_vpc_endpoint" "workspace" {
  vpc_id              = module.vpc.vpc_id
  service_name        = local.private_link.workspace_service
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = module.vpc.intra_subnets
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${local.prefix}-vpce-workspace" })
}

# 3.2 AWS VPC Endpoint - Relay(SCC)
resource "aws_vpc_endpoint" "relay" {
  vpc_id              = module.vpc.vpc_id
  service_name        = local.private_link.relay_service
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = module.vpc.intra_subnets
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${local.prefix}-vpce-relay" })
}

# 3.3 Databricks Account에 Workspace VPC Endpoint 등록
resource "databricks_mws_vpc_endpoint" "workspace" {
  provider            = databricks.mws
  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.workspace.id
  vpc_endpoint_name   = "${local.prefix}-workspace-vpce"
  region              = var.region
  depends_on          = [aws_vpc_endpoint.workspace]
}

# 3.4 Databricks Account에 Relay VPC Endpoint 등록
resource "databricks_mws_vpc_endpoint" "relay" {
  provider            = databricks.mws
  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.relay.id
  vpc_endpoint_name   = "${local.prefix}-relay-vpce"
  region              = var.region
  depends_on          = [aws_vpc_endpoint.relay]
}
```

### 3.5 Databricks Network 구성(VPC Endpoint 연결) — `mws_network.tf`

```hcl
resource "databricks_mws_networks" "this" {
  provider           = databricks.mws
  account_id         = var.databricks_account_id
  network_name       = "${local.prefix}-network"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [aws_security_group.dataplane.id]

  # 여기서 backend PrivateLink 연결
  vpc_endpoints {
    dataplane_relay = [databricks_mws_vpc_endpoint.relay.vpc_endpoint_id]
    rest_api        = [databricks_mws_vpc_endpoint.workspace.vpc_endpoint_id]
  }

  depends_on = [
    aws_vpc_endpoint.workspace,
    aws_vpc_endpoint.relay,
  ]
}
```

### 3.6 Private Access Settings — `pas.tf`

```hcl
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
```

> - `public_access_enabled = true` + backend VPCE 등록 = **Backend PrivateLink**(데이터 플레인만 사설, 웹 UI는 공용)
> - `public_access_enabled = false` = **Frontend PrivateLink**까지 강제(6장 옵션 참고)

### 3.7 (선택) Zerobus Ingest 사설 인입 PrivateLink — `privatelink_zerobus.tf`

**"Inbound private link for performance-intensive services"** 엔드포인트입니다.
Zerobus Ingest(443)로의 **인입(frontend)** 연결을 사설화합니다(service-direct).
**backend PrivateLink와는 독립**이며, 지금 당장 필요 없더라도
`var.enable_zerobus_privatelink = true` 한 번으로 켤 수 있게 스캐폴딩해 둡니다.

> ⚠️ 아래 순서 주의(공식 문서 권장):
> 1. AWS VPC Endpoint 생성 시 **`private_dns_enabled = false`** — 등록 전에 private DNS를 켜면
>    트래픽이 곧바로 PrivateLink로 가면서 **등록 완료 전까지 거부**됩니다.
> 2. Databricks Account에 endpoint 등록(`databricks_mws_vpc_endpoint`).
> 3. 등록 후 **Route53 private hosted zone**으로
>    `<region>.service-direct.privatelink.cloud.databricks.com` 을 이 endpoint로 resolve.

```hcl
# 3.7.1 AWS VPC Endpoint - Zerobus Ingest / service-direct (performance-intensive inbound)
resource "aws_vpc_endpoint" "zerobus" {
  count               = var.enable_zerobus_privatelink ? 1 : 0
  vpc_id              = module.vpc.vpc_id
  service_name        = local.private_link.zerobus_service
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = module.vpc.intra_subnets
  private_dns_enabled = false   # ← 등록 전에는 반드시 false (아래 Route53으로 대체)

  tags = merge(var.tags, { Name = "${local.prefix}-vpce-zerobus" })
}

# 3.7.2 Databricks Account에 Zerobus VPC Endpoint 등록
resource "databricks_mws_vpc_endpoint" "zerobus" {
  count               = var.enable_zerobus_privatelink ? 1 : 0
  provider            = databricks.mws
  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.zerobus[0].id
  vpc_endpoint_name   = "${local.prefix}-zerobus-vpce"
  region              = var.region
  depends_on          = [aws_vpc_endpoint.zerobus]
}

# 3.7.3 Route53 private hosted zone으로 service-direct DNS를 endpoint에 매핑
#   (private_dns_enabled=false 이므로 직접 CNAME/ALIAS로 연결)
resource "aws_route53_zone" "zerobus" {
  count = var.enable_zerobus_privatelink ? 1 : 0
  name  = local.zerobus_dns_name          # <region>.service-direct.privatelink.cloud.databricks.com
  vpc {
    vpc_id = module.vpc.vpc_id
  }
  tags = var.tags
}

resource "aws_route53_record" "zerobus" {
  count   = var.enable_zerobus_privatelink ? 1 : 0
  zone_id = aws_route53_zone.zerobus[0].zone_id
  name    = local.zerobus_dns_name
  # zone apex(정점)에는 CNAME이 허용되지 않으므로(InvalidChangeBatch),
  # VPC endpoint를 가리키는 ALIAS A 레코드를 사용합니다.
  type = "A"
  alias {
    name                   = aws_vpc_endpoint.zerobus[0].dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.zerobus[0].dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}
```

> ⚠️ **왜 CNAME이 아니라 ALIAS A 인가** (실제 apply로 확인한 이슈)
> hosted zone 이름과 레코드 이름이 같은 **zone apex**에는 CNAME을 만들 수 없습니다
> (`InvalidChangeBatch: RRSet of type CNAME ... is not permitted at apex`). 그래서
> VPC endpoint의 `dns_entry[0]`의 `dns_name`·`hosted_zone_id`를 참조하는 **ALIAS A
> 레코드**로 apex를 endpoint에 매핑합니다.

> 📌 **켜는 방법**: `terraform.tfvars`에 `enable_zerobus_privatelink = true` 를 추가하고
> `terraform apply`. **끄면** 관련 리소스만 정리되고 backend/워크스페이스에는 영향이 없습니다.
> Zerobus용 SG는 이미 443 인바운드가 열려 있는 `aws_security_group.vpce`를 재사용합니다.
>
> 자세한 절차/검증(`dig <region>.service-direct.privatelink.cloud.databricks.com`)은
> 공식 문서 참고: https://docs.databricks.com/aws/en/security/network/front-end/service-direct-privatelink

---

## 4. Cross-account IAM Role & Root Storage — `credentials_storage.tf`

```hcl
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
```

---

## 5. 워크스페이스 생성 — `workspace.tf`

```hcl
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
  pricing_tier    = "ENTERPRISE"   # PrivateLink는 ENTERPRISE 필요

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
    suffix                 = local.suffix                 # "-xxxxxx" 또는 ""
    prefix                 = local.prefix                 # 리소스 공통 접두어
    workspace_name         = local.prefix
    root_bucket            = "${local.prefix}-rootbucket"
    uc_catalog_bucket      = local.uc_catalog_bucket_name
    uc_catalog_root_path   = "s3://${local.uc_catalog_bucket_name}/catalog-root"
    uc_catalog_name        = local.uc_catalog_name
    metastore_id           = local.metastore_id
    metastore_reused       = !local.create_metastore   # true면 기존 metastore 재활용
  }
}
```

---

## 6. Unity Catalog — Metastore & **Managed Default Catalog Root Bucket 지정**

여기서 요구사항의 핵심인 **UC Managed default catalog의 root bucket 위치 설정**을 다룹니다.

권장 아키텍처(최신 UC):
- **Metastore는 storage_root 없이(또는 리전당 1개) 생성** — 최신 UC는 metastore-level storage 없이 **catalog-level 및 workspace-level** 스토리지를 권장.
- **Catalog마다 `storage_root`(managed location)를 지정** → 각 카탈로그의 managed table 데이터가 지정한 S3 버킷에 저장됩니다.

### 6.1 UC용 S3 버킷 & IAM Role — `uc_storage.tf`

```hcl
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
```

> 📌 UC master role ARN(`414351767826`)은 **AWS 상용 리전 공통값**입니다.
> GovCloud 등은 다르므로 배포 리전에 맞는 값을 문서에서 확인하세요.

### 6.2 Metastore 생성 & 워크스페이스 할당 — `uc_metastore.tf`

```hcl
# storage_root 없이 metastore 생성 (catalog 별 스토리지 사용)
# existing_metastore_id가 지정되면(count=0) 생성하지 않고 기존 것을 재활용합니다.
# UC는 "리전당 metastore 1개" 제한이 있어, 같은 리전에 이미 있으면 재활용해야 합니다.
resource "databricks_metastore" "this" {
  count    = local.create_metastore ? 1 : 0
  provider = databricks.mws
  name     = "${local.prefix}-metastore"
  region   = var.region
  # metastore owner(=metastore admin). 우선순위:
  #   1) metastore_owner_group 지정 시 → 해당 그룹(6.2.5 admin_groups.tf에서 생성/채택)
  #   2) 아니면 unity_admin_group (하위 호환)
  #   3) 둘 다 비었으면 owner 생략 → metastore를 만든 SP가 자동으로 owner
  # owner는 Account에 실존하는 그룹/사용자/SP여야 합니다.
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
```

> ⚠️ **왜 `time_sleep`과 "배포 SP를 owner 그룹에 추가"가 필요한가** (실제 재설치로 확인한 이슈)
>
> 이 계정처럼 리전에 metastore가 이미 있으면, 워크스페이스는 생성 직후 UC가 **리전 기본
> metastore에 자동 연결**합니다. 그 상태에서 곧바로 catalog/credential/external location을
> 만들면 그 **잘못된 metastore**에 생성되고, 뒤이어 우리 metastore로 재할당되면서
> 워크스페이스 UI 카탈로그 목록에서 사라집니다. 두 가지로 방지합니다.
> 1. **`time_sleep.metastore_assignment_propagation`**: 재할당이 workspace-scope UC API에
>    전파될 때까지 기다린 뒤 UC 리소스를 생성 → 항상 "새로 할당된(또는 재활용한) metastore"에
>    카탈로그가 붙습니다. 대기 시간은 `var.metastore_assignment_propagation`(기본 60s)로 조정.
> 2. **배포 SP를 metastore owner 그룹에 추가**(6.2.5): metastore owner를 그룹으로 넘기면
>    배포 SP가 metastore admin이 아니게 되어 external location/catalog 생성이
>    `PERMISSION_DENIED`로 실패합니다. SP를 owner 그룹 멤버로 넣어 admin 권한을 유지합니다.

> ♻️ **기존 metastore 재활용**
> - 같은 리전에 이미 metastore가 있으면 `terraform.tfvars`에 `existing_metastore_id = "<uuid>"`를 지정하세요.
>   → 새로 만들지 않고 그 metastore를 이 워크스페이스에 할당만 합니다.
> - 기존 metastore ID 확인: `databricks account metastores list`
> - 빈 값(기본)이면 `${local.prefix}-metastore` 이름으로 새로 생성합니다.
> - ⚠️ 재활용 시 `terraform destroy`는 **metastore를 삭제하지 않습니다**(생성 안 했으므로).
>   assignment만 해제됩니다 — 공유 metastore를 실수로 지우지 않아 안전합니다.
> - ⚠️ 재활용 시에는 `enable_random_suffix=true`가 강제됩니다(precondition). suffix가 없으면
>   storage credential / external location / catalog 이름이 공유 metastore 안에서 충돌하기 때문입니다.

### 6.2.5 Metastore owner / Workspace admin 그룹 자동 구성 — `admin_groups.tf`

설치 직후 metastore admin·workspace admin에는 **배포용 SP만** 들어 있고 실제 사용자는
비어 있어, 매번 콘솔에서 수동으로 사용자를 admin에 넣어줘야 했습니다. 이 파일은
`terraform.tfvars`로 받은 **그룹 이름 + 이메일 목록**으로 이 과정을 자동화합니다.

```hcl
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

# Metastore owner 그룹 / Workspace admin 그룹.
# force=true: Account에 같은 이름 그룹이 있으면 채택, 없으면 생성.
resource "databricks_group" "metastore_owner" {
  count        = local.manage_metastore_owner_group ? 1 : 0
  provider     = databricks.mws
  display_name = var.metastore_owner_group
  force        = true
}

resource "databricks_group" "workspace_admin" {
  count        = local.manage_workspace_admin_group ? 1 : 0
  provider     = databricks.mws
  display_name = var.workspace_admin_group
  force        = true
}

# 그룹 멤버십. 나열된 이메일만 추가하며, 그룹에 원래 있던 다른 멤버는 건드리지 않음.
resource "databricks_group_member" "metastore_owner" {
  provider  = databricks.mws
  for_each  = local.manage_metastore_owner_group ? toset(var.metastore_owner_members) : toset([])
  group_id  = databricks_group.metastore_owner[0].id
  member_id = databricks_user.admin[each.value].id
}

resource "databricks_group_member" "workspace_admin" {
  provider  = databricks.mws
  for_each  = local.manage_workspace_admin_group ? toset(var.workspace_admin_members) : toset([])
  group_id  = databricks_group.workspace_admin[0].id
  member_id = databricks_user.admin[each.value].id
}

# 배포용 SP(=이 Terraform을 실행하는 principal).
# metastore owner를 그룹으로 넘기면 이 SP가 metastore admin이 아니게 되어
# storage credential / external location / catalog 생성이 PERMISSION_DENIED로 실패합니다.
# 그래서 SP를 owner 그룹 멤버로 넣어 admin 권한을 유지시킵니다.
data "databricks_service_principal" "deployer" {
  count          = local.manage_metastore_owner_group ? 1 : 0
  provider       = databricks.mws
  application_id = var.databricks_client_id
}

resource "databricks_group_member" "metastore_owner_deployer" {
  count     = local.manage_metastore_owner_group ? 1 : 0
  provider  = databricks.mws
  group_id  = databricks_group.metastore_owner[0].id
  member_id = data.databricks_service_principal.deployer[0].sp_id
}

# Workspace admin 그룹을 워크스페이스에 ADMIN 권한으로 할당.
# (metastore owner 매핑은 6.2 uc_metastore.tf 의 owner 로 처리)
resource "databricks_mws_permission_assignment" "workspace_admin" {
  count        = local.manage_workspace_admin_group ? 1 : 0
  provider     = databricks.mws
  workspace_id = databricks_mws_workspaces.this.workspace_id
  principal_id = databricks_group.workspace_admin[0].id
  permissions  = ["ADMIN"]
}
```

`terraform.tfvars` 예시:

```hcl
metastore_owner_group   = "metastore_owners"
metastore_owner_members = ["alice@example.com", "bob@example.com"]
workspace_admin_group   = "workspace_admins"
workspace_admin_members = ["alice@example.com", "carol@example.com"]
```

> 🔑 **동작 요약** (실제 destroy→재설치로 검증됨)
> - 그룹 이름이 Account에 **이미 있으면 채택**, **없으면 생성**합니다(`force=true`).
>   → 같은 이름 그룹이 존재해도 `already exists` 에러 없이 그대로 재사용됩니다.
> - `*_members`의 이메일이 Account에 **없으면 사용자 생성** 후 그룹에 추가, **있으면 채택**해 추가.
>   그룹에 원래 있던 다른 멤버는 그대로 둡니다.
> - `metastore_owner_group` → metastore **owner(=metastore admin)** 로 매핑(6.2와 연동).
> - `workspace_admin_group` → 워크스페이스 **ADMIN 권한**으로 매핑.
> - 그룹 이름을 빈 값(`""`, 기본)으로 두면 해당 그룹 자동 구성을 건너뜁니다.

### 6.3 Storage Credential, External Location & Default Catalog — `uc_catalog.tf`

```hcl
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
  provider     = databricks.workspace
  name         = local.uc_catalog_name
  storage_root = databricks_external_location.uc_catalog.url  # ← root bucket 위치 지정
  comment      = "Managed default catalog for aws-rnd-root"
  isolation_mode = "OPEN"
  force_destroy  = true

  depends_on = [
    databricks_external_location.uc_catalog,
  ]
}

# 이 카탈로그를 워크스페이스의 기본(default) 카탈로그로 설정
resource "databricks_default_namespace_setting" "this" {
  provider  = databricks.workspace
  namespace {
    value = databricks_catalog.default.name
  }
}

output "default_catalog_storage_location" {
  value = databricks_catalog.default.storage_location
}
```

> ✅ **핵심 포인트**
> - `databricks_catalog.storage_root` 가 곧 해당 catalog의 managed table root bucket 위치입니다.
> - 이 값을 바꾸면 **새 카탈로그가 재생성**(ForceNew)되므로 처음에 신중히 지정하세요.
> - `databricks_default_namespace_setting`으로 해당 카탈로그를 워크스페이스 default로 지정합니다.

---

## 7. 배포 (Apply)

Account 레벨 → 워크스페이스 레벨 순서로 의존성이 자동 해결되지만,
provider `databricks.workspace`가 워크스페이스 URL에 의존하므로 **2단계 apply**를 권장합니다.

```bash
cd /Users/stefano.jang/workspace/dbx-terraform-install/databricks-aws

# 0) 환경변수 확인
echo "$AWS_PROFILE / $AWS_REGION"
aws sts get-caller-identity --profile aws-rnd-root

# 1) 초기화
terraform init

# 2) 포맷/검증
terraform fmt -recursive
terraform validate

# 3) 계획 확인
terraform plan -out=tfplan

# 4) 1단계: 워크스페이스까지 먼저 생성 (workspace provider 의존성 회피)
terraform apply \
  -target=databricks_mws_workspaces.this \
  -target=databricks_mws_networks.this \
  -target=databricks_mws_vpc_endpoint.workspace \
  -target=databricks_mws_vpc_endpoint.relay \
  -target=databricks_mws_private_access_settings.pas

# 5) 2단계: 나머지(Unity Catalog 등) 전체 적용
terraform apply tfplan
# 또는
terraform apply
```

> 💡 `-target` 없이 한 번에 `apply`해도 대부분 성공하지만, 워크스페이스 provider가
> 아직 없는 URL을 참조하려다 실패할 수 있습니다. 위 2단계 방식이 가장 안전합니다.

### 7.1 AI 에이전트(Vibe / Claude Code)로 실행하기

사용자가 직접 CLI를 치는 대신 **Vibe 에이전트나 Claude Code**에게 배포를 맡길 수 있습니다.
에이전트는 위 명령들을 순서대로 실행하고, 에러가 나면 원인을 진단해 코드/문서를 고친 뒤
재시도합니다(이 가이드의 부록 A 오류 표가 그 근거가 됩니다).

**1) 자격증명 준비 (한 번만)**

민감정보는 셸 환경변수로 주입합니다. 에이전트의 실행 셸은 매 명령마다 새로 뜨므로,
`export`와 실제 명령을 **한 줄로 이어서** 실행해야 값이 유지됩니다.

```bash
# AWS는 프로파일로 (예: aws-rnd-root)
aws sts get-caller-identity --profile aws-rnd-root

# Databricks Account OAuth SP는 TF_VAR_* 로 (0.3에서 발급)
export TF_VAR_databricks_account_id="<account-uuid>"
export TF_VAR_databricks_client_id="<oauth-client-id>"
export TF_VAR_databricks_client_secret="<oauth-client-secret>"
```

> ⚠️ Claude Code에서는 프롬프트에 `!` 프리픽스로 `! export TF_VAR_...`를 실행하면
> **사용자 셸**에 값이 남아, 시크릿을 대화창에 노출하지 않고 재사용할 수 있습니다.
> 다만 에이전트의 도구 셸은 이를 상속하지 않으므로, 도구가 apply를 돌릴 때는
> `export ... && terraform apply ...`처럼 한 명령에 함께 넣습니다.

**2) 에이전트에게 줄 지시 예시**

```
databricks-aws/ 의 Terraform으로 워크스페이스를 배포해줘.
- TF_VAR_databricks_* 는 이미 export 돼 있어(또는 아래 값으로 export해줘).
- terraform.tfvars 의 prefix/버킷명은 그대로 쓰고, enable_random_suffix=true 유지.
- 7장의 2단계 apply 순서를 따르고, 에러가 나면 부록 A를 참고해 코드를 고친 뒤 재시도해줘.
- 완료되면 `terraform output resolved_names` 로 최종 이름을 보여줘.
```

**3) 에이전트가 수행하는 일 (내부적으로)**

```bash
cd databricks-aws
export TF_VAR_databricks_account_id="..." TF_VAR_databricks_client_id="..." \
  TF_VAR_databricks_client_secret="..."
terraform init
terraform fmt -recursive && terraform validate
# 1단계
terraform apply -auto-approve \
  -target=databricks_mws_credentials.this \
  -target=databricks_mws_storage_configurations.this \
  -target=databricks_mws_networks.this \
  -target=databricks_mws_private_access_settings.pas \
  -target=databricks_mws_workspaces.this
# 2단계
terraform apply -auto-approve
terraform output resolved_names
```

> 🔒 **에이전트 사용 시 주의**
> - `apply`/`destroy`는 실제 클라우드 리소스와 비용을 발생시키므로, 자동 실행 전
>   사용자 확인을 받도록 하세요(Claude Code의 권한 모드 활용).
> - 시크릿을 커밋하지 않도록 `terraform.tfvars`·state는 `.gitignore`로 제외돼 있습니다.
> - 배포 검증이 끝나면 OAuth SP 시크릿을 **로테이트**하는 것을 권장합니다.

---

## 8. 검증 (Verification)

### 8.1 워크스페이스 접속

```bash
terraform output workspace_url
# 브라우저로 접속 → Account admin 계정으로 로그인
```

### 8.2 Databricks CLI로 PrivateLink/네트워크 확인

```bash
# CLI 프로파일 구성 (OAuth)
databricks configure --host $(terraform output -raw workspace_url)

# 워크스페이스 상태
databricks account workspaces list --output json | jq '.[] | {workspace_name, workspace_status}'
```

### 8.3 Backend PrivateLink 실제 검증

```bash
# 클러스터를 하나 띄운 뒤, driver 노드에서 relay/REST 도메인이
# VPC Endpoint 사설 IP로 resolve 되는지 확인 (private_dns_enabled=true 효과)
# 노트북에서:
%sh nslookup <workspace-host>     # VPC endpoint 사설 IP(10.10.3.x 대역) 반환되어야 함
```

- 클러스터가 정상적으로 **RUNNING**이 되면 Relay(SCC) PrivateLink가 정상 동작하는 것입니다.
- 클러스터가 `Bootstrap Timeout`으로 실패하면 → Relay VPCE / 보안그룹 6666 포트 / DNS 설정 점검.

### 8.4 UC Default Catalog & Root Bucket 확인

```sql
-- 워크스페이스 SQL Editor 또는 노트북에서
-- (카탈로그 이름은 suffix가 붙을 수 있음. 실제 이름은 `terraform output resolved_names`의
--  uc_catalog_name 값으로 치환하세요. 아래는 suffix 없이 default일 때 예시)
SELECT current_catalog();          -- main_rnd_root 반환 확인

DESCRIBE CATALOG EXTENDED main_rnd_root;  -- Storage Root가 지정한 s3 경로인지 확인

-- 실제 managed table 생성 → S3 버킷에 데이터 적재되는지 확인
CREATE TABLE main_rnd_root.default.test_tbl AS SELECT 1 AS id;
```

```bash
# S3에서 실제 데이터 경로 확인
# (suffix가 붙을 수 있으므로 실제 버킷명은 terraform output에서 확인)
BUCKET_PATH=$(terraform output -json resolved_names | jq -r '.uc_catalog_root_path')
aws s3 ls "${BUCKET_PATH}/" --profile aws-rnd-root --recursive | head
```

---

## 9. (옵션) Frontend PrivateLink까지 완전 사설화

사용자→워크스페이스 웹 UI 접근까지 사설로 잠그려면:

1. `databricks_mws_private_access_settings`에서 `public_access_enabled = false`
2. 사용자 접근용 네트워크(예: Transit Gateway/온프레 VPN)에서 workspace VPC Endpoint로 라우팅
3. 프라이빗 호스팅 존(Route53)으로 워크스페이스 도메인을 VPCE로 resolve

```hcl
resource "databricks_mws_private_access_settings" "pas" {
  provider                     = databricks.mws
  private_access_settings_name = "${local.prefix}-pas"
  region                       = var.region
  public_access_enabled        = false          # frontend까지 사설 강제
  private_access_level         = "ACCOUNT"
}
```

---

## 10. 정리 (Destroy)

```bash
# UC/카탈로그 등 워크스페이스 레벨부터 역순으로 제거됨
terraform destroy

# 버킷에 객체가 남아있어 실패하면 force_destroy=true 확인 또는 수동 비우기
# (suffix가 붙을 수 있으므로 실제 버킷명은 terraform output에서 확인)
BUCKET=$(terraform output -json resolved_names | jq -r '.uc_catalog_bucket')
aws s3 rm "s3://${BUCKET}" --recursive --profile aws-rnd-root
```

> ⚠️ **destroy가 subnet/security group에서 `DependencyViolation`으로 멈출 때**
> (실제 재설치 중 겪은 이슈)
>
> destroy 시점에 워크스페이스에 **실행 중인 클러스터**가 있으면, 워크스페이스가 먼저
> 삭제돼도 그 클러스터의 **워커 EC2 노드**(`Vendor=Databricks`, ENI 설명 `databricks_netif`)가
> 고아로 남아 subnet/security group을 붙들어 삭제가 실패합니다.
> ```
> Error: deleting Security Group (sg-...): DependencyViolation
> Error: deleting EC2 Subnet (subnet-...): ... has dependencies and cannot be deleted
> ```
> **예방:** destroy 전에 워크스페이스의 모든 클러스터를 종료(terminate)하세요.
> **이미 발생했다면** 남은 ENI가 붙은 인스턴스를 찾아 종료 후 `terraform destroy`를 재실행:
> ```bash
> # 1) 삭제 실패한 subnet에 남은 ENI 조회
> aws ec2 describe-network-interfaces --region <region> \
>   --filters "Name=subnet-id,Values=<subnet-id>" \
>   --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Desc:Description,Inst:Attachment.InstanceId}'
> # 2) ENI가 붙은 인스턴스가 Databricks 워커인지 확인 (Vendor=Databricks 태그)
> aws ec2 describe-instances --region <region> --instance-ids <instance-id> \
>   --query 'Reservations[].Instances[].Tags'
> # 3) 고아 워커 종료 → ENI 자동 해제 → destroy 재실행
> aws ec2 terminate-instances --region <region> --instance-ids <instance-id>
> terraform destroy   # ENI 빠진 뒤 subnet/SG/VPC 정상 삭제
> ```

---

## 부록 A. 자주 겪는 오류 & 해결

| 증상 | 원인 | 해결 |
|------|------|------|
| `MALFORMED_REQUEST: Private link ...` | VPCE 서비스 이름이 리전과 불일치 | `locals.private_link` 값을 리전 최신값으로 교체(부록 B 참고) |
| 클러스터 `Bootstrap Timeout` | Relay VPCE 미등록/SG 6666 차단 | Relay VPCE, SG egress 6666, DNS 점검 |
| workspace provider `host` 오류 | 1단계 apply 전 workspace URL 없음 | 7장의 2단계 apply 사용 |
| Metastore 리전당 1개 제한 | 동일 리전 metastore 이미 존재 | `terraform.tfvars`에 `existing_metastore_id = "<uuid>"` 지정해 재활용(6.2 참고). ID는 `databricks account metastores list`로 확인 |
| `cannot create mws credentials: Failed credential validation checks` | 방금 만든 cross-account IAM role이 아직 AWS 전역 전파 전 | 4장의 `time_sleep.iam_propagation`으로 대기하지만, 전파가 느리면 드물게 발생 → 잠시 후 재-apply |
| `cannot create metastore: Could not find principal with name ...` | metastore owner로 지정한 그룹/사용자가 Account에 없음 | `metastore_owner_group`을 쓰면 그룹이 자동 생성/채택되므로 해결(6.2.5 참고). 또는 `unity_admin_group`을 실존 그룹으로 지정하거나 둘 다 비워 생성 SP가 owner가 되게 함(6.2 참고) |
| NAT Gateway `Resource.AlreadyAssociated` | 중단된 apply로 EIP가 이미 다른 NAT에 연결됨 | failed NAT 삭제 후 정상 NAT를 `terraform import`, 또는 둘 다 삭제 후 재-apply |
| destroy 시 `DependencyViolation` (subnet/security group) | 실행 중이던 클러스터의 Databricks 워커 EC2(ENI `databricks_netif`)가 고아로 남아 subnet/SG를 점유 | destroy 전 클러스터 종료. 이미 발생 시 남은 ENI가 붙은 인스턴스를 종료 후 `terraform destroy` 재실행(10장 참고) |
| 설치는 성공했는데 워크스페이스 카탈로그 목록에 default 카탈로그가 안 보임 | 리전에 metastore가 이미 있어, 재할당 전파 전에 카탈로그가 "리전 기본 metastore"에 잘못 생성됨(레이스) | `time_sleep.metastore_assignment_propagation`(6.2, 기본 60s)으로 방지하지만, 전파가 느리면 발생 → `metastore_assignment_propagation`을 90s 등으로 늘려 재-apply |
| apply가 `No valid credential sources` / `SSO token has expired`로 즉시 실패 | AWS SSO 세션 만료 | `aws sso login --profile aws-rnd-root`로 세션 갱신 후 재-apply(0.4 참고) |
| `Group/User already exists` 없이 admin 그룹이 채택됨 | `metastore_owner_group`/`workspace_admin_group`이 Account에 이미 존재 | 정상 동작(오류 아님). `force=true`가 기존 그룹/사용자를 에러 없이 채택(6.2.5 참고) |

## 부록 B. PrivateLink 서비스 엔드포인트 최신값 확인처

- Databricks 공식 문서: **"IP addresses and domains → PrivateLink VPC endpoint services"** →
  `https://docs.databricks.com/aws/en/resources/ip-domain-region#privatelink-vpc-endpoint-services`
  → 리전별 `workspace_service`(REST API) / `relay_service`(SCC) VPC Endpoint Service 이름 표
- 참고: **"Enable AWS PrivateLink"** →
  `https://docs.databricks.com/aws/en/security/network/classic/privatelink`

## 부록 C. 파일 구조 요약

```
databricks-aws/
├── .terraform-version       # (선택) tfenv용 Terraform 버전 고정 (예: 1.15.8)
├── versions.tf              # provider 버전
├── providers.tf             # aws / databricks(mws, workspace)
├── variables.tf             # 변수 정의
├── locals.tf                # PrivateLink 서비스 이름 등
├── terraform.tfvars         # 비민감 변수값
├── network.tf               # VPC, 서브넷, 보안그룹
├── privatelink.tf           # backend PrivateLink VPCE (workspace + relay)
├── privatelink_zerobus.tf   # (선택) Zerobus Ingest 사설 인입 VPCE + Route53
├── mws_network.tf           # databricks_mws_networks (+ vpc_endpoints)
├── pas.tf                   # private access settings
├── credentials_storage.tf   # cross-account IAM + root S3 + storage config
├── workspace.tf             # databricks_mws_workspaces
├── uc_storage.tf            # UC용 S3 버킷 + IAM role
├── uc_metastore.tf          # metastore + assignment (+ 전파 대기)
├── admin_groups.tf          # metastore owner / workspace admin 그룹 자동 구성
└── uc_catalog.tf            # storage credential + external location + default catalog
```

## 부록 D. 설치용 AWS Profile 최소 권한

이 Terraform을 실행하는 AWS profile(IAM User 또는 Assumed Role)은 아래 AWS 서비스에
대해 리소스를 **생성·수정·삭제**합니다. 부트스트랩 단계에서는 **`AdministratorAccess`
관리형 정책**을 붙이는 것이 가장 간단하며, 조직 정책상 최소 권한이 필요할 때 아래 목록을
참고하세요.

| 서비스 | Terraform이 만드는 것 | 필요한 대표 액션 |
|--------|----------------------|------------------|
| **IAM** | cross-account role, UC catalog role + inline policy | `iam:CreateRole`, `iam:DeleteRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:PassRole`, `iam:GetRole`, `iam:ListRolePolicies`, `iam:TagRole` |
| **S3** | root 버킷 / UC catalog 버킷 (+정책·암호화·public block) | `s3:CreateBucket`, `s3:DeleteBucket`, `s3:PutBucketPolicy`, `s3:PutEncryptionConfiguration`, `s3:PutBucketPublicAccessBlock`, `s3:Get*`, `s3:List*` |
| **VPC / EC2** | VPC, subnet, route table, IGW, NAT GW, EIP, security group | `ec2:*Vpc*`, `ec2:*Subnet*`, `ec2:*RouteTable*`, `ec2:*InternetGateway*`, `ec2:*NatGateway*`, `ec2:*Address*`, `ec2:*SecurityGroup*`, `ec2:Describe*`, `ec2:CreateTags`, `ec2:DeleteTags` |
| **VPC Endpoint (PrivateLink)** | workspace / relay / (옵션) zerobus 엔드포인트 | `ec2:CreateVpcEndpoint`, `ec2:DeleteVpcEndpoints`, `ec2:ModifyVpcEndpoint`, `ec2:DescribeVpcEndpoints` |
| **Route53** | (옵션) Zerobus용 private hosted zone + 레코드 | `route53:CreateHostedZone`, `route53:DeleteHostedZone`, `route53:ChangeResourceRecordSets`, `route53:Get*`, `route53:List*` |
| **STS** | 현재 계정 ID 조회 (`data.aws_caller_identity`) | `sts:GetCallerIdentity` |

> ⚠️ **핵심 주의**
> - **IAM Role 생성이 관문입니다.** `iam:CreateRole` / `iam:PassRole`이 조직 SCP나
>   permission boundary에 막히면 Databricks cross-account role·UC storage role을
>   만들 수 없어 설치가 실패합니다.
> - Route53 권한은 **`enable_zerobus_privatelink = true`** 일 때만 필요합니다(기본 off).
> - 위는 **AWS 쪽 권한**입니다. 이와 별개로 **Databricks Account 쪽 자격증명**
>   (account admin 권한 Service Principal의 `client_id`/`client_secret`, `account_id`)이
>   필요합니다(0.2·0.3 참고).
> - 이 표는 **가이드 참고용**입니다. 특정 정책 JSON을 그대로 붙이면 액션 누락·리전
>   조건 등으로 apply가 막힐 수 있으니, 최소 권한을 쓸 경우 apply 로그의 `AccessDenied`
>   메시지를 보며 해당 액션을 추가하는 방식을 권장합니다.
