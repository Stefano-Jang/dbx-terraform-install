# Databricks on AWS — Terraform (Backend PrivateLink)

AWS에 **Backend PrivateLink**로 사설화된 Databricks 워크스페이스를 Terraform으로 배포합니다.
VPC/네트워크, PrivateLink VPC Endpoint, Cross-account IAM, Root S3, Unity Catalog
(Metastore · Storage Credential · External Location · Managed Default Catalog)까지 한 번에 구성합니다.

상세 설명은 [`databricks-aws-terraform-install.md`](./databricks-aws-terraform-install.md) 를 참고하세요.

## 구성 요소

| 파일 | 역할 |
|---|---|
| `versions.tf` / `providers.tf` | Terraform·provider 버전, aws / databricks(mws, workspace) provider |
| `variables.tf` / `locals.tf` | 변수 정의, 이름 조립(suffix), 리전별 PrivateLink 서비스명 |
| `network.tf` / `mws_network.tf` | VPC, 서브넷, 보안그룹, Databricks network 등록 |
| `privatelink.tf` / `pas.tf` | Backend PrivateLink VPC Endpoint(REST·Relay), Private Access Settings |
| `privatelink_zerobus.tf` | (선택) Zerobus Ingest 사설 인입 PrivateLink |
| `credentials_storage.tf` | Cross-account IAM Role, Root S3 버킷, MWS credentials/storage 등록 |
| `workspace.tf` | 워크스페이스 생성 및 출력(output) |
| `uc_storage.tf` / `uc_metastore.tf` / `uc_catalog.tf` | Unity Catalog S3·IAM, Metastore, Storage Credential, External Location, Default Catalog |

## 사전 요구 사항

- **Terraform** >= 1.5 (tfenv 사용 시 `tfenv install && tfenv use <version>`)
- **AWS CLI** 프로파일 (기본: `aws-rnd-root`) — VPC/IAM/S3/VPC Endpoint/Route53 생성 권한.
  설치용 profile에는 **`AdministratorAccess` 관리형 정책 권장**(최소 권한은 설치 가이드 부록 D 참고)
- **Databricks Account** 및 Account 인증용 **OAuth Service Principal**(client_id/secret)
- 대상 리전의 **PrivateLink VPC Endpoint Service 이름** — `locals.tf`의 `private_link` 값을
  [공식 문서](https://docs.databricks.com/aws/en/resources/ip-domain-region#privatelink-vpc-endpoint-services)의
  최신값으로 반드시 교체

## 빠른 시작

```bash
cd databricks-aws

# 1) 변수 파일 준비 (tfvars는 .gitignore로 커밋 제외됨)
cp terraform.tfvars.example terraform.tfvars
#   → terraform.tfvars 를 열어 prefix / region / 버킷명 등 수정

# 2) 민감정보는 환경변수로 주입
export TF_VAR_databricks_account_id="<account-id>"
export TF_VAR_databricks_client_id="<oauth-client-id>"
export TF_VAR_databricks_client_secret="<oauth-client-secret>"

# 3) 초기화 & 검증
terraform init
terraform fmt -check -recursive
terraform validate

# 4) 배포
terraform plan
terraform apply

# 5) 배포 결과 확인
terraform output resolved_names   # 실제 적용된 이름들(suffix 포함)
terraform output workspace_url
```

## AI 에이전트(Vibe / Claude Code)로 실행

CLI를 직접 치는 대신 에이전트에게 배포를 맡길 수 있습니다. 자격증명을 export한 뒤
아래처럼 지시하면, 에이전트가 2단계 apply를 순서대로 돌리고 에러 시
가이드 부록 A를 참고해 고친 뒤 재시도합니다.

```
databricks-aws/ 의 Terraform으로 워크스페이스를 배포해줘.
enable_random_suffix=true 유지하고, 7장의 2단계 apply 순서를 따라줘.
에러가 나면 부록 A를 참고해 코드를 고친 뒤 재시도하고,
완료되면 terraform output resolved_names 를 보여줘.
```

- 에이전트 셸은 명령마다 새로 뜨므로 `export ... && terraform apply ...`처럼 한 줄로 실행됩니다.
- `apply`/`destroy`는 실제 리소스·비용을 만들므로 자동 실행 전 확인을 받게 하세요.
- 자세한 내용은 가이드 **7.1 AI 에이전트로 실행하기** 참고.

## 주요 옵션 (terraform.tfvars)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `prefix` | `rnd-root-dbx` | 모든 리소스 이름의 접두어 |
| `uc_catalog_bucket_name` | `...-uc-catalog-root` | UC managed catalog root S3 버킷 (전역 고유) |
| `uc_catalog_name` | `main_rnd_root` | UC 카탈로그 이름 (언더스코어 사용) |
| `enable_random_suffix` | `true` | 이름 뒤에 랜덤 suffix를 붙여 **여러 SA 재활용 시 충돌 방지** |
| `set_deployment_name` | `false` | workspace URL 도메인을 prefix로 지정(Account에 prefix 등록 선행 필요) |
| `existing_metastore_id` | `""` | 지정 시 기존 metastore 재활용(리전당 1개 제한 회피) |
| `metastore_owner_group` | `""` | metastore owner(=admin) 그룹 이름. 없으면 생성/있으면 채택 |
| `metastore_owner_members` | `[]` | metastore owner 그룹에 넣을 이메일 목록 |
| `workspace_admin_group` | `""` | workspace admin(ADMIN 권한) 그룹 이름. 없으면 생성/있으면 채택 |
| `workspace_admin_members` | `[]` | workspace admin 그룹에 넣을 이메일 목록 |
| `metastore_assignment_propagation` | `"60s"` | metastore 재할당 후 UC 라우팅 전파 대기(카탈로그 가시성 레이스 방지) |
| `enable_zerobus_privatelink` | `false` | Zerobus Ingest 사설 인입 PrivateLink 생성 |

### 이름 충돌 방지 (여러 SA가 같은 설정 재활용)

`enable_random_suffix = true`(기본)이면 `prefix`·버킷명 뒤에 `-xxxxxx`, 카탈로그 이름 뒤에
`_xxxxxx` 형태의 랜덤 suffix가 붙어, 여러 SA가 동일한 tfvars로 배포해도 S3 버킷명(전역 고유)·
IAM role·UC 카탈로그 등이 충돌하지 않습니다.

고객 환경에 **정해진 이름 그대로** 설치해야 하면 `enable_random_suffix = false`로 두세요.

### 기존 metastore 재활용

UC는 "리전당 metastore 1개" 제한이 있습니다. 같은 리전에 이미 metastore가 있으면:

```bash
databricks account metastores list          # 기존 metastore ID 확인
```

`terraform.tfvars`에 `existing_metastore_id = "<uuid>"`를 지정하면 새로 만들지 않고
그 metastore를 워크스페이스에 할당만 합니다. (이 경우 `enable_random_suffix=true` 필수)

### Metastore owner / Workspace admin 그룹 자동 구성

설치 직후 metastore admin·workspace admin에는 배포용 SP만 들어 있고 실제 사용자는
비어 있어 매번 수동으로 지정해야 합니다. 아래 값을 `terraform.tfvars`에 넣으면 설치 시
자동으로 admin 그룹과 사용자를 구성합니다.

```hcl
metastore_owner_group   = "metastore_owners"
metastore_owner_members = ["alice@example.com", "bob@example.com"]
workspace_admin_group   = "workspace_admins"
workspace_admin_members = ["alice@example.com", "carol@example.com"]
```

동작:

- 그룹 이름이 Account에 **이미 있으면 채택**하고, **없으면 새로 생성**합니다(`force=true`).
- `*_members`의 이메일이 Account에 **없으면 사용자를 생성**한 뒤 그룹에 추가하고, **이미 있으면**
  그대로 채택해 그룹에 추가합니다. 그룹에 원래 있던 다른 멤버는 건드리지 않습니다.
- `metastore_owner_group` → metastore **owner(=metastore admin)** 로 매핑됩니다.
  (기존 `unity_admin_group`보다 우선)
- `workspace_admin_group` → 워크스페이스 **ADMIN 권한**(`databricks_mws_permission_assignment`)으로 매핑됩니다.
- metastore owner를 그룹으로 지정하면 **배포 SP도 그 owner 그룹의 멤버로 추가**됩니다.
  (SP가 metastore admin 권한을 유지해야 storage credential/external location/catalog를 만들 수 있음)

그룹 이름을 빈 값(`""`, 기본)으로 두면 해당 그룹 자동 구성을 건너뜁니다.

### 카탈로그가 올바른 metastore에 붙도록 보장

리전에 metastore가 이미 있는 계정에서는, 워크스페이스 생성 직후 UC가 이를 **리전 기본
metastore에 자동 연결**합니다. 이 상태에서 곧바로 카탈로그를 만들면 엉뚱한 metastore에
생성되어 워크스페이스 목록에서 보이지 않는 레이스가 발생합니다. 이를 막기 위해
`databricks_metastore_assignment` 후 `time_sleep`(`metastore_assignment_propagation`,
기본 60s)으로 재할당 전파를 기다린 뒤에 catalog/credential/external location을 생성합니다.
→ **새로 만든 metastore(또는 `existing_metastore_id`로 재활용한 metastore)에 카탈로그가 붙습니다.**

## 정리 (Destroy)

```bash
cd databricks-aws
terraform destroy
```

> `existing_metastore_id`로 재활용한 경우 destroy는 metastore를 삭제하지 않고 할당만 해제합니다.

## 참고

- `terraform.tfvars` 및 `*.tfstate`, `.terraform/`는 `.gitignore`로 커밋되지 않습니다.
  민감정보(account_id 등)를 커밋하지 않도록 주의하세요.
- 상세 단계별 가이드: [`databricks-aws-terraform-install.md`](./databricks-aws-terraform-install.md)
