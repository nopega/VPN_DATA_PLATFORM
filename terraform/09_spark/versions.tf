terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      Stage     = "09_spark"
      ManagedBy = "terraform"
    }
  }
}

data "terraform_remote_state" "data" {
  backend = "local"
  config  = { path = "${path.module}/../06_data_foundation/terraform.tfstate" }
}

locals {
  logs_bucket = data.terraform_remote_state.data.outputs.logs_bucket
  logs_arn    = "arn:aws:s3:::${local.logs_bucket}"
}
