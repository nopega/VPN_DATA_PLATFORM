output "certificate_arn" {
  description = "Wildcard certificate. The controller finds it on its own from an Ingress's spec.tls hosts, so manifests do not need this."
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

output "certificate_domain" {
  value = aws_acm_certificate.wildcard.domain_name
}
