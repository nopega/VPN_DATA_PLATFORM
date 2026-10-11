terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      Stage     = "04_ingress"
      ManagedBy = "terraform"
    }
  }
}

# Reads the token from the CLOUDFLARE_API_TOKEN environment variable, so it
# never appears in a .tf file or in terraform.tfstate.
provider "cloudflare" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# Talks to the Kubernetes API -- over Tailscale, since the endpoint is
# private. Each call gets a fresh token from `aws eks get-token`, using the
# same AWS credentials as Terraform itself.
provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}
