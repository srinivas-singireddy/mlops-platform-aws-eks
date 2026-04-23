# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # REQUIRED for EKS — don't forget.
  tags                 = { Name = "${var.name}-vpc" }

}

# -----------------------------------------------------------------------------
# Internet Gateway (for public subnets)
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }

}

# -----------------------------------------------------------------------------
# Subnets
# Public subnets carry the kubernetes.io/role/elb tag so AWS Load Balancer
# Controller knows where to place public ALBs. Private subnets get
# kubernetes.io/role/internal-elb. These tags aren't strictly needed yet
# (no EKS cluster), but adding them now means no modification later.
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.name}-public-${var.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                              = "${var.name}-private-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# NAT instance (cost-optimized alternative to NAT Gateway)
# -----------------------------------------------------------------------------

# Amazon Linux 2023 AMI (ARM64 for t4g)
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
}

resource "aws_security_group" "nat" {
  name        = "${var.name}-nat-sg"
  description = "Allow outbound internet from private subnets via this instance"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "All traffic from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-nat-sg" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

resource "aws_network_interface" "nat" {
  subnet_id         = aws_subnet.public[0].id
  security_groups   = [aws_security_group.nat.id]
  source_dest_check = false # CRITICAL for NAT forwarding.
  tags              = { Name = "${var.name}-nat-eni" }
}

resource "aws_eip_association" "nat" {
  allocation_id        = aws_eip.nat.id
  network_interface_id = aws_network_interface.nat.id
}

resource "aws_instance" "nat" {
  ami           = data.aws_ami.al2023_arm.id
  instance_type = var.nat_instance_type

  network_interface {
    network_interface_id = aws_network_interface.nat.id
    device_index         = 0
  }

  # Enable IP forwarding + iptables masquerading on boot
  user_data = <<-EOF
    #!/bin/bash
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    /sbin/iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
    # Persist iptables across reboots
    dnf install -y iptables-services
    /sbin/iptables-save > /etc/sysconfig/iptables
    systemctl enable --now iptables
  EOF

  tags = { Name = "${var.name}-nat" }
}


# -----------------------------------------------------------------------------
# Route tables
# -----------------------------------------------------------------------------


# Public: default route to IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private: default route to NAT instance ENI
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_network_interface.nat.id
  }

  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# -----------------------------------------------------------------------------
# VPC Endpoints
# S3 gateway endpoint is FREE and saves NAT bandwidth for ECR image pulls
# (since ECR uses S3 under the hood). Gateway endpoints attach to route tables.
# -----------------------------------------------------------------------------


resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3-endpoint" }
}

data "aws_region" "current" {}



