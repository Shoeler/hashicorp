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
  address = "http://127.0.0.1:8200"
  token   = "root" # Dev mode root token
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-vault-demo"
}
