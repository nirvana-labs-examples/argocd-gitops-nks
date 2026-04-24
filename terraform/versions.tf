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

# The k8s providers read from the kubeconfig written by the NKS module. The
# file doesn't exist on the first apply — use `terraform apply -target=module.nks`
# for phase 1 so these providers aren't invoked. `load_config_file` on the
# kubectl provider is gated on the path being non-null to avoid an eager
# read during init.
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
  load_config_file = module.nks.kubeconfig_path != null
}
