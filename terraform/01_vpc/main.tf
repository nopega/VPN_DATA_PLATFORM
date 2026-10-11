# Stage 01 -- the network, and nothing else.
#
# Everything here is free except the optional NAT gateway (off by default):
# a VPC, its subnets, route tables, an internet gateway and an S3 gateway
# endpoint all cost $0 per hour and $0 per GB.
#
# Layout with the defaults (10.42.0.0/16, three zones):
#
#   10.42.0.0/24    public  zone a    load balancers (if any ever face the internet), NAT
#   10.42.1.0/24    public  zone b
#   10.42.2.0/24    public  zone c
#   10.42.32.0/19   private zone a    nodes and pods
#   10.42.64.0/19   private zone b
#   10.42.96.0/19   private zone c
#
# Private subnets are large on purpose. The AWS VPC CNI gives every pod a real
# address from the subnet, so pods -- not nodes -- are what uses addresses up.
# A /19 holds about 8,000.

data "aws_availability_zones" "available" {
  state = "available"

  # Skip Local Zones and Wavelength Zones; EKS cannot use them as normal zones.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # cidrsubnet(range, extra_bits, index):
  #   /16 + 8 bits = /24, index 0,1,2       -> 10.42.0.0/24, 10.42.1.0/24, 10.42.2.0/24
  #   /16 + 3 bits = /19, index 1,2,3       -> 10.42.32.0/19, 10.42.64.0/19, 10.42.96.0/19
  # Index 0 of the /19s (10.42.0.0/19) is skipped because the /24s live inside it.
  public_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 3, i + 1)]

  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both are required by EKS. dns_hostnames also lets the internal load
  # balancer's name resolve to private addresses for anyone inside the VPC
  # or on the Tailscale network.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.project_name }
}

# The default security group allows all traffic between its own members.
# Nothing should use it, so take every rule away: anything that forgets to
# name a security group gets no access rather than broad access.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-default-locked" }
}

# ---------------------------------------------------------------------------
# Public side: subnets whose default route goes to the internet gateway
# ---------------------------------------------------------------------------

# The VPC's door to the internet. Free. Translates addresses one-to-one for
# anything that owns a public address (a NAT gateway, an internet-facing load
# balancer). Without one, nothing in the VPC can be reached from or reach the
# internet at all.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.project_name }
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.public_cidrs[count.index]

  # Nothing launched here gets a public address unless it asks for one.
  # Load balancers and NAT gateways bring their own; an EC2 instance that
  # silently received one would be exposed by accident.
  map_public_ip_on_launch = false

  tags = merge(local.cluster_tag, {
    Name = "${var.project_name}-public-${local.azs[count.index]}"
    # Where the AWS Load Balancer Controller puts an internet-facing load balancer.
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Private side: no route to the internet gateway, ever
# ---------------------------------------------------------------------------

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_cidrs[count.index]

  tags = merge(local.cluster_tag, {
    Name = "${var.project_name}-private-${local.azs[count.index]}"
    # Where the AWS Load Balancer Controller puts an INTERNAL load balancer.
    # This is the tag the VPN design depends on: the ALB moves here.
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# One route table per zone rather than one shared, so that a NAT gateway per
# zone can be added later by changing routes, not by re-plumbing subnets.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# Optional NAT gateway (the only paid resource in this stage)
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat" }
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  # A NAT gateway must sit in a PUBLIC subnet: it reaches the internet
  # through the internet gateway like anything else with a public address.
  subnet_id = aws_subnet.public[0].id

  tags       = { Name = var.project_name }
  depends_on = [aws_internet_gateway.this]
}

# Single NAT for every zone (a second one would add another ~$47/mo): the same availability trade the original
# platform made. If zone a fails, the other zones lose outbound internet.
resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint -- free, and keeps warehouse traffic off the NAT
# ---------------------------------------------------------------------------

# Not a device: it adds a route for S3's address ranges to each private route
# table. Works whether or not the NAT gateway exists, so pods can read and
# write the Iceberg warehouse even with enable_nat_gateway = false.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${var.project_name}-s3" }
}
