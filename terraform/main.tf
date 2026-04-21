module "nks" {
  source = "git::https://github.com/nirvana-labs/terraform-nirvana-nks.git?ref=main"

  cluster_name = var.cluster_name
  project_id   = var.project_id
  region       = var.region

  node_pools = {
    default = {
      node_count    = var.node_count
      instance_type = var.instance_type
    }
  }

  fetch_kubeconfig = var.fetch_kubeconfig
}

locals {
  ingress_ip      = coalesce(var.ingress_public_ip, module.nks.ingress_vip)
  argocd_hostname = coalesce(var.argocd_hostname, "argocd.${local.ingress_ip}.nip.io")

  argocd_chart_path = "${path.module}/../argocd/argocd"
}

# ArgoCD installed by Terraform. After it comes up, the cert-manager
# Application (below) syncs the wrapper chart from this repo — which
# includes the Let's Encrypt ClusterIssuer in its templates.
resource "helm_release" "argocd" {
  count = var.fetch_kubeconfig ? 1 : 0

  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  chart = local.argocd_chart_path

  values = [file("${local.argocd_chart_path}/values.yaml")]

  set {
    name  = "argo-cd.global.domain"
    value = local.argocd_hostname
  }

  set {
    name  = "argo-cd.server.ingress.extraTls[0].hosts[0]"
    value = local.argocd_hostname
  }
}

# Self-management Application — identical to bootstrap-tf.
resource "kubectl_manifest" "argocd_self_app" {
  count = var.fetch_kubeconfig ? 1 : 0

  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "argocd"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_repo_url
        targetRevision = var.argocd_repo_branch
        path           = "argocd/argocd"
        helm = {
          releaseName = "argocd"
          parameters = [
            { name = "argo-cd.global.domain", value = local.argocd_hostname },
            { name = "argo-cd.server.ingress.extraTls[0].hosts[0]", value = local.argocd_hostname },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
      }
    }
  })
}

# cert-manager as an ArgoCD Application — the key difference from bootstrap-tf.
# Points at argocd/cert-manager/ wrapper chart, which installs cert-manager
# via a dependency on the jetstack chart AND applies a ClusterIssuer from
# its own templates/ once the cert-manager CRDs are registered.
resource "kubectl_manifest" "cert_manager_app" {
  count = var.fetch_kubeconfig && var.letsencrypt_email != null ? 1 : 0

  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "cert-manager"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.argocd_repo_url
        targetRevision = var.argocd_repo_branch
        path           = "argocd/cert-manager"
        helm = {
          releaseName = "cert-manager"
          parameters = [
            { name = "letsencryptEmail", value = var.letsencrypt_email },
            { name = "acmeServer", value = var.letsencrypt_acme_server },
          ]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "cert-manager"
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
          # Required: cert-manager Application creates CRDs AND resources
          # that depend on those CRDs (the ClusterIssuer) in one sync.
          "SkipDryRunOnMissingResource=true",
        ]
      }
    }
  })
}

# Optional: SSH deploy key for private forks — identical to bootstrap-tf.
resource "kubernetes_secret" "argocd_repo" {
  count = var.fetch_kubeconfig && var.repo_ssh_private_key_path != null ? 1 : 0

  depends_on = [helm_release.argocd]

  metadata {
    name      = "argocd-repo"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = var.argocd_repo_url
    sshPrivateKey = file(pathexpand(var.repo_ssh_private_key_path))
  }
}
