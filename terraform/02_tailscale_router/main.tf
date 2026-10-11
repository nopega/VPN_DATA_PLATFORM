# Stage 02 -- one small EC2 instance with two jobs:
#
#   1. Tailscale subnet router. Joins the Tailscale network and advertises the
#      VPC range (10.42.0.0/16), so a laptop on Tailscale can reach private
#      addresses inside the VPC.
#   2. NAT instance. Private subnets send 0.0.0.0/0 here, and it forwards that
#      traffic to the internet under its own public address.
#
# Traffic paths through it:
#
#   laptop --Tailscale tunnel--> router --(source rewritten to router)--> 10.42.x.x
#   node in private subnet --> router --(source rewritten to router)--> internet
#
# It lives in a PUBLIC subnet with a public address because both jobs need the
# internet: Tailscale to reach its coordination servers, NAT by definition.
#
# Cost in ap-southeast-1: instance ~$3.70/mo, public IPv4 ~$3.65/mo,
# 8 GiB gp3 ~$0.80/mo, the secret $0.40/mo -- about $8.50/mo in total.

# ---------------------------------------------------------------------------
# Inputs from stage 01
# ---------------------------------------------------------------------------

# Reads stage 01's state file directly from disk. Works because both stages
# use local state in sibling folders; switch to the s3 backend here when
# stage 01 moves to S3.
data "terraform_remote_state" "vpc" {
  backend = "local"
  config = {
    path = "${path.module}/../01_vpc/terraform.tfstate"
  }
}

locals {
  vpc          = data.terraform_remote_state.vpc.outputs
  vpc_id       = local.vpc.vpc_id
  vpc_cidr     = local.vpc.vpc_cidr
  router_az    = local.vpc.availability_zones[0]
  router_net   = local.vpc.public_subnet_ids[0]
  private_rts  = local.vpc.private_route_table_ids
  # Terraform does not store an output whose value is null, so while stage 01
  # has no NAT gateway this attribute is simply absent -- try() reads that as null.
  stage01_nat  = try(local.vpc.nat_gateway_public_ip, null)
}

# Latest Amazon Linux 2023 for ARM, published by AWS as a public parameter.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# Metadata only (name, ARN). Does NOT read the secret's value.
data "aws_secretsmanager_secret" "tailscale_auth_key" {
  name = var.tailscale_auth_key_secret_name
}

# ---------------------------------------------------------------------------
# Identity: what the instance itself is allowed to do
# ---------------------------------------------------------------------------

resource "aws_iam_role" "router" {
  name = "${var.project_name}-router"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Read exactly one secret: the auth key. Nothing else in Secrets Manager.
resource "aws_iam_role_policy" "read_auth_key" {
  name = "read-tailscale-auth-key"
  role = aws_iam_role.router.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = data.aws_secretsmanager_secret.tailscale_auth_key.arn
    }]
  })
}

# Session Manager: a shell on the instance from the AWS console or CLI,
# without opening SSH or keeping a key pair anywhere.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.router.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "router" {
  name = "${var.project_name}-router"
  role = aws_iam_role.router.name
}

# ---------------------------------------------------------------------------
# Network: what may reach the instance
# ---------------------------------------------------------------------------

resource "aws_security_group" "router" {
  name        = "${var.project_name}-router"
  description = "Tailscale subnet router and NAT instance"
  vpc_id      = local.vpc_id
  tags        = { Name = "${var.project_name}-router" }
}

# Everything from inside the VPC. This is the NAT job: a node in a private
# subnet sends its internet-bound packets here.
resource "aws_vpc_security_group_ingress_rule" "from_vpc" {
  security_group_id = aws_security_group.router.id
  description       = "NAT: traffic from private subnets"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "-1"
}

# Tailscale's own port. Not strictly required -- without it Tailscale still
# works through its relay servers -- but open, laptops can build a direct
# tunnel, which is faster. The traffic on it is WireGuard: encrypted and
# authenticated, so nothing unauthenticated gets past this port.
resource "aws_vpc_security_group_ingress_rule" "tailscale_direct" {
  security_group_id = aws_security_group.router.id
  description       = "Tailscale direct connections (WireGuard)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
}

# No SSH rule on purpose. Shell access is through Session Manager.

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.router.id
  description       = "Out to anywhere: Tailscale, package repos, and NAT for the VPC"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_instance" "router" {
  # insecure_value, not value: this parameter is public, and `value` is
  # marked sensitive, which would hide the AMI id in every plan.
  ami                  = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type        = var.instance_type
  subnet_id            = local.router_net
  iam_instance_profile = aws_iam_instance_profile.router.name

  vpc_security_group_ids      = [aws_security_group.router.id]
  associate_public_ip_address = true

  # By default EC2 drops packets that are not addressed to the instance
  # itself. A router and a NAT exist to handle exactly those packets.
  source_dest_check = false

  # Instance metadata only through session tokens (IMDSv2): blocks the
  # classic trick of tricking a process into fetching role credentials.
  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region           = var.region
    secret_id        = data.aws_secretsmanager_secret.tailscale_auth_key.arn
    vpc_cidr         = local.vpc_cidr
    hostname         = var.tailscale_hostname
    act_as_nat       = var.act_as_nat
  })

  # A changed boot script only runs on a fresh instance, so rebuild rather
  # than silently keeping the old behaviour. (Needs a REUSABLE auth key --
  # a one-off key is spent on the first boot.)
  user_data_replace_on_change = true

  lifecycle {
    # The parameter above points at the newest AMI, which AWS replaces every
    # few weeks. Without this, every plan after a new release would want to
    # destroy and rebuild a router that is working fine.
    ignore_changes = [ami]
  }

  tags = { Name = "${var.project_name}-router" }

  depends_on = [aws_iam_role_policy.read_auth_key]
}

# ---------------------------------------------------------------------------
# Private subnets: send internet-bound traffic to the instance
# ---------------------------------------------------------------------------

resource "aws_route" "private_via_router" {
  count = var.act_as_nat ? length(local.private_rts) : 0

  route_table_id         = local.private_rts[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.router.primary_network_interface_id

  lifecycle {
    precondition {
      condition     = local.stage01_nat == null
      error_message = "Stage 01 already has a NAT gateway owning 0.0.0.0/0 in the private route tables. Set act_as_nat = false here, or enable_nat_gateway = false in stage 01."
    }
  }
}
