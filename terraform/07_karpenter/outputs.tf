output "controller_role_arn" {
  value = module.karpenter.iam_role_arn
}

output "interruption_queue" {
  value = module.karpenter.queue_name
}

output "node_role_name" {
  description = "Set as spec.role in the EC2NodeClass (apps repo)."
  value       = element(split("/", local.node_role_arn), length(split("/", local.node_role_arn)) - 1)
}

output "discovery_tag" {
  description = "Selector the EC2NodeClass uses for subnets and security groups."
  value       = "${local.discovery_tag.key}=${local.discovery_tag.value}"
}
