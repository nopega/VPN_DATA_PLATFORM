output "instance_id" {
  value = aws_instance.router.id
}

output "private_ip" {
  description = "Ping this from a laptop on Tailscale to prove the tunnel works."
  value       = aws_instance.router.private_ip
}

output "public_ip" {
  description = "The address private subnets reach the internet from. Changes if the instance is stopped and started."
  value       = aws_instance.router.public_ip
}

output "shell" {
  description = "Open a shell on the router (needs the Session Manager plugin for the AWS CLI)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.router.id}"
}

output "bootstrap_log" {
  description = "Read the first-boot log without opening a shell."
  value       = "aws ec2 get-console-output --region ${var.region} --instance-id ${aws_instance.router.id} --latest --output text | tail -40"
}
