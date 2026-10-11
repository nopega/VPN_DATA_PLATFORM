terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is kept on local disk for now: free, and enough for one operator.
  # Move it to an S3 backend before a second person runs `terraform apply`,
  # otherwise two copies of the state will disagree about what exists.
}

provider "aws" {
  region = var.region

  # Every resource in this stage gets these tags, so the AWS console can
  # filter "everything this project created" in one search.
  default_tags {
    tags = {
      Project   = var.project_name
      Stage     = "01_vpc"
      ManagedBy = "terraform"
    }
  }
}
