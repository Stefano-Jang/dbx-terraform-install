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
