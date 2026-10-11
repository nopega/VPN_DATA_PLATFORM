output "url" {
  value = "https://${var.hostname}"
}

output "initial_admin_password" {
  description = "Command that prints the first admin password. Change it after logging in, then delete the secret."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}
