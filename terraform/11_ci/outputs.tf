output "runs_on" {
  description = "Put this in a workflow's `runs-on:`."
  value       = var.runner_scale_set_name
}
