terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.8.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17.0"
    }
  }
}

provider "vault" {
  address = "http://localhost:8080"
  token   = var.vault_dev_token
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-${var.cluster_name}"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kind-${var.cluster_name}"
  }
}
