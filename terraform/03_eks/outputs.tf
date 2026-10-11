output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Resolves to private addresses in the VPC. Reachable only over Tailscale."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  description = "The group EKS created; control plane and every node are members."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "kubeconfig" {
  description = "Writes this cluster into ~/.kube/config. Then kubectl works -- while Tailscale is connected."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}
