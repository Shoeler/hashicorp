terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "vault" {
  address = "http://localhost:8080"
  token   = "root" # Dev mode root token
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-vault-demo"
}
