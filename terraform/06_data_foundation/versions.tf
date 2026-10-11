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
      Stage     = "06_data_foundation"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "vpc" {
  backend = "local"
  config = {
    path = "${path.module}/../01_vpc/terraform.tfstate"
  }
}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_cidr           = data.terraform_remote_state.vpc.outputs.vpc_cidr
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
}
