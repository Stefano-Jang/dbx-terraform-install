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
  # one()은 count=0이면 null, count=1이면 그 값을 반환 → 빈 리스트 [0] 인덱싱 에러 방지
  metastore_id = local.create_metastore ? one(databricks_metastore.this[*].id) : var.existing_metastore_id

  # PrivateLink용 리전별 서비스 이름 (VPC Endpoint Service).
  # ⚠️ 아래는 예시이며 리전마다 다릅니다.
  # 리전별 workspace(REST API) / relay(SCC) VPC Endpoint Service 이름 표:
  # https://docs.databricks.com/aws/en/resources/ip-domain-region#privatelink-vpc-endpoint-services
  private_link = {
    # ap-northeast-2 (Seoul) 예시 - 배포 전 반드시 최신 값으로 교체
    # 표의 "General access (including REST API)" 값
    workspace_service = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0babb9bde64f34d7e"
    # 표의 "Secure cluster connectivity relay" 값
    relay_service = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0dc0e98a5800db5c4"
    # 표의 "Inbound private link for performance-intensive services" 값
    #   (Zerobus Ingest 사설 인입용).
    #   기본 배포에는 미사용이며, var.enable_zerobus_privatelink=true 일 때만 3.7에서 사용.
    zerobus_service = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0eda2860bd3ffdc62"
  }

  # Zerobus/service-direct 인입이 resolve해야 하는 리전별 DNS 호스트명
  # (private_dns_enabled 대신 Route53 private hosted zone으로 이 이름을 endpoint에 매핑)
  zerobus_dns_name = "${var.region}.service-direct.privatelink.cloud.databricks.com"
}
