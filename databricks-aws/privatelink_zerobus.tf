# 3.7.1 AWS VPC Endpoint - Zerobus Ingest / service-direct (performance-intensive inbound)
resource "aws_vpc_endpoint" "zerobus" {
  count               = var.enable_zerobus_privatelink ? 1 : 0
  vpc_id              = module.vpc.vpc_id
  service_name        = local.private_link.zerobus_service
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpce.id]
  subnet_ids          = module.vpc.intra_subnets
  private_dns_enabled = false # ← 등록 전에는 반드시 false (아래 Route53으로 대체)

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
  name  = local.zerobus_dns_name # <region>.service-direct.privatelink.cloud.databricks.com
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
