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
  intra_subnets  = ["10.10.3.0/24", "10.10.4.0/24"]
  public_subnets = ["10.10.101.0/24", "10.10.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

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
