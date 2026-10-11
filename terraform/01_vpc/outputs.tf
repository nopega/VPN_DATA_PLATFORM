# Later stages read these with a terraform_remote_state data source (or copy
# them), so the cluster is built into exactly these subnets.

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "The range Tailscale will advertise to users in the VPN stage."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  value = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

output "nat_gateway_public_ip" {
  description = "Empty while enable_nat_gateway is false."
  value       = try(aws_eip.nat[0].public_ip, null)
}

output "subnet_layout" {
  description = "Human-readable map of what went where."
  value = {
    for i, az in local.azs : az => {
      public  = local.public_cidrs[i]
      private = local.private_cidrs[i]
    }
  }
}
