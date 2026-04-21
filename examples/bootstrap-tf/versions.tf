terraform {
  required_version = ">= 1.5"
  required_providers {
    nirvana = {
      source  = "nirvana-labs/nirvana"
      version = ">= 1.41"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

provider "nirvana" {}

# All three k8s providers read from the kubeconfig written by the NKS module
# on the second apply. Until then (fetch_kubeconfig = false), the file does
# not exist — resources that use these providers are count-gated on
# var.fetch_kubeconfig to avoid errors.
provider "helm" {
  kubernetes {
    config_path = module.nks.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = module.nks.kubeconfig_path
}

provider "kubectl" {
  config_path      = module.nks.kubeconfig_path
  load_config_file = true
}
