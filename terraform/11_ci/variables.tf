variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "vpn-data-platform"
}

variable "cluster_name" {
  type    = string
  default = "vpn-data-platform"
}

variable "arc_version" {
  description = "Actions Runner Controller; the controller and scale-set charts must be the same version."
  type        = string
  default     = "0.15.0"
}

variable "github_config_url" {
  description = "Repository whose workflows these runners serve."
  type        = string
  default     = "https://github.com/nopega/vpn-data-platform-apps"
}

variable "runner_scale_set_name" {
  description = "What workflows put in `runs-on:`."
  type        = string
  default     = "vpn-data-platform"
}

variable "max_runners" {
  description = "Upper bound of concurrent jobs. Each runner asks for 2 vCPU / 4 GiB."
  type        = number
  default     = 2
}
