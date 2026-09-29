# "Light" cuts everything the full stack (../standard/network.tf)
# spends on private-subnet compute: no NAT gateway, no VPC Flow Logs, no VPC
# endpoints. All three instances (edge/app/worker, ec2.tf) sit in the SAME
# public subnet — security groups, not subnet placement, are what keeps
# app/worker unreachable from the internet (see below). RDS still gets
# private subnets: nothing on the public internet should ever reach it
# directly, and only sg-app/sg-worker are allowed to.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# All three instances' home, and the only place anything in this stack has
# a route to the internet gateway. One subnet, not three: nothing here is
# highly available (a single edge/app/worker instance each), so spreading
# across AZs would buy fault tolerance this stack doesn't otherwise have.
resource "aws_subnet" "public" {
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)
  vpc_id                  = aws_vpc.this.id
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public" }
}

# RDS's subnet group requires two AZs even for a single-AZ instance — these
# carry no route to the IGW, so nothing in them is reachable from the
# internet regardless of any security group.
resource "aws_subnet" "private" {
  count             = var.az_count
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 1)
  vpc_id            = aws_vpc.this.id
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.name_prefix}-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# No route table association for the private subnets: the main route table
# AWS creates per-VPC (no explicit association) already covers them with a
# local-only route — no NAT, no IGW, no path out. That is deliberate, not an
# omission.

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.name_prefix}-db", Component = "database" }
}

# ---- Security groups --------------------------------------------------------
#
# Four, one per compute role plus RDS — replacing what used to be one shared
# EC2 security group. This is what actually keeps app/worker out of reach of
# the internet now that all three instances share one public subnet: each
# SG's ingress list names exactly which OTHER security group may reach it,
# never a CIDR, except sg-edge's own internet-facing rule (and even that is
# scoped to CloudFront's own IP range, not the whole internet — see below).

# CloudFront (cloudfront.tf) is the only thing allowed to reach this
# instance from outside the VPC — its origin-facing IP range is a stable,
# AWS-managed prefix list, not "the internet" the way a plain 0.0.0.0/0
# ingress rule would be. Nginx itself still checks a shared-secret header
# CloudFront injects (cloudfront.tf, ec2.tf) as defense in depth beyond this
# IP restriction alone.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# No SSH ingress anywhere in this file, on purpose: iam.tf attaches
# AmazonSSMManagedInstanceCore to every instance role, so operator shell
# access goes through SSM Session Manager (outbound-only, no listening port,
# every session logged) instead of an open port 22.
resource "aws_security_group" "edge" {
  name_prefix = "${var.name_prefix}-edge-"
  description = "nginx: reverse-proxies to app, serves the built frontend directly. Ingress from CloudFront only, never the raw internet."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-edge", Component = "network" }

  ingress {
    description     = "HTTP from CloudFront's origin-facing range only (cloudfront.tf terminates the public-facing TLS)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  # api egress to app is a SEPARATE aws_security_group_rule below, same
  # cross-reference-cycle reasoning as app/worker's valkey rule.
  egress {
    description = "HTTPS for its own from-source build (S3, Secrets Manager, Go/npm registries) and SSM"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name_prefix}-app-"
  description = "api + valkey. Ingress on 8080 from edge only, on 6379 from worker only — never the internet."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-app", Component = "network" }

  # api ingress from edge, and valkey ingress from worker, are SEPARATE
  # aws_security_group_rule resources below, not inline here — edge/app and
  # app/worker each reference the OTHER's SG id, and Terraform can't
  # resolve two security groups' inline rule blocks each depending on the
  # other's id in the same apply (a real dependency cycle, not just an
  # ordering nuisance).

  # Postgres egress to RDS is a SEPARATE aws_security_group_rule below —
  # same mutual-reference cycle as the pairs already externalized above.
  egress {
    description = "HTTPS to third-party APIs, S3, Secrets Manager, Go module proxy"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Outbound mail relay (SMTP submission/implicit-TLS/plain)"
    from_port   = 25
    to_port     = 25
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 465
    to_port     = 465
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 587
    to_port     = 587
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "worker" {
  name_prefix = "${var.name_prefix}-worker-"
  description = "worker. No ingress from anywhere — nothing calls it; it only ever connects out."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-worker", Component = "network" }

  # valkey egress to app is the other half of the separate
  # aws_security_group_rule pair below — see the note on app's own ingress
  # block above for why this can't be an inline block here.
  # Postgres egress to RDS is a SEPARATE aws_security_group_rule below —
  # same mutual-reference cycle as the pairs already externalized above.
  egress {
    description = "HTTPS to third-party APIs, S3, Secrets Manager, Go module proxy"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Outbound mail relay (SMTP submission/implicit-TLS/plain)"
    from_port   = 25
    to_port     = 25
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 465
    to_port     = 465
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 587
    to_port     = 587
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name_prefix}-db-"
  description = "RDS Postgres — ingress from app and worker on 5432 only, no egress (RDS never originates outbound traffic)."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-db", Component = "database" }

  # Both ingress rules are SEPARATE aws_security_group_rule resources below
  # — db and app/worker each reference the OTHER's SG id, the same
  # mutual-reference cycle as the pairs already externalized above.

  lifecycle { create_before_destroy = true }
}

# The one mutual reference in this file — app needs ingress FROM worker on
# 6379, worker needs egress TO app on 6379 — split out of both SGs' inline
# blocks above into their own resources, the standard fix for the
# cross-reference cycle two inline blocks referencing each other's SG id
# would otherwise create.
resource "aws_security_group_rule" "app_ingress_api_from_edge" {
  type                     = "ingress"
  description              = "api, from edge"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.edge.id
}

resource "aws_security_group_rule" "edge_egress_api_to_app" {
  type                     = "egress"
  description              = "To the app instance"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.edge.id
  source_security_group_id = aws_security_group.app.id
}

resource "aws_security_group_rule" "app_ingress_valkey_from_worker" {
  type                     = "ingress"
  description              = "valkey, from worker"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "worker_egress_valkey_to_app" {
  type                     = "egress"
  description              = "valkey, on the app instance"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.app.id
}

resource "aws_security_group_rule" "app_egress_postgres_to_db" {
  type                     = "egress"
  description              = "Postgres, to RDS"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = aws_security_group.db.id
}

resource "aws_security_group_rule" "db_ingress_postgres_from_app" {
  type                     = "ingress"
  description              = "Postgres from the app instance"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.app.id
}

resource "aws_security_group_rule" "worker_egress_postgres_to_db" {
  type                     = "egress"
  description              = "Postgres, to RDS"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.db.id
}

resource "aws_security_group_rule" "db_ingress_postgres_from_worker" {
  type                     = "ingress"
  description              = "Postgres from the worker instance"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.worker.id
}
