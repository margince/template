# One VPC with one public subnet. No NAT gateway: the Elastic IP is also the
# egress address (Docker pulls, ACME).

locals {
  vpc_cidr = "10.30.0.0/16"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.name_prefix}-public" }
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

# Inbound: 80 and 443 from the internet (Caddy: certificate challenge,
# redirect, the application), 22 from ssh_allowed_cidrs only. Outbound open.
resource "aws_security_group" "host" {
  name        = "${var.name_prefix}-host"
  description = "Margince host: HTTP and HTTPS from anywhere, SSH from ssh_allowed_cidrs only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name_prefix}-host" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.host.id
  description       = "HTTP for the certificate challenge and the redirect to HTTPS"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.host.id
  description       = "HTTPS, the application"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.ssh_allowed_cidrs)
  security_group_id = aws_security_group.host.id
  description       = "SSH for make host-bootstrap and make deploy"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  description       = "All outbound: Docker pulls, ACME, third-party APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
