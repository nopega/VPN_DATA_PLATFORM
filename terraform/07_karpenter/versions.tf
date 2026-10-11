terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59" # the karpenter module needs >= 6.59
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project_name
      Stage     = "07_karpenter"
      ManagedBy = "terraform"
    }
  }
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

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

data "terraform_remote_state" "vpc" {
  backend = "local"
  config  = { path = "${path.module}/../01_vpc/terraform.tfstate" }
}

data "terraform_remote_state" "eks" {
  backend = "local"
  config  = { path = "${path.module}/../03_eks/terraform.tfstate" }
}
