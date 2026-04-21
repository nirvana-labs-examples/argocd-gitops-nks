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

  # Paths to the shared wrapper charts, relative to this example directory
  argocd_chart_path = "${path.module}/../../argocd/argocd"
}

# cert-manager from jetstack upstream. installCRDs=true registers the CRDs
# needed by the ClusterIssuer below.
resource "helm_release" "cert_manager" {
  count = var.fetch_kubeconfig && var.letsencrypt_email != null ? 1 : 0

  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true

  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.15.3"

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# HTTP-01 ClusterIssuer. kubectl_manifest (alekc/kubectl) is used instead of
# kubernetes_manifest because the hashicorp/kubernetes provider reads CRD
# schemas at plan time — and cert-manager's CRDs only exist after
# helm_release.cert_manager applies. kubectl_manifest skips schema lookup.
resource "kubectl_manifest" "letsencrypt_issuer" {
  count = var.fetch_kubeconfig && var.letsencrypt_email != null ? 1 : 0

  depends_on = [helm_release.cert_manager]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        email  = var.letsencrypt_email
        server = var.letsencrypt_acme_server
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [{
          http01 = {
            ingress = { class = "cilium" }
          }
        }]
      }
    }
  })
}

# ArgoCD installed from the local wrapper chart (argocd/argocd/). The chart
# depends on the upstream argo-cd chart; values.yaml nests overrides under
# `argo-cd:`. This is the same path that ArgoCD's self-management
# Application reconciles against (see Task 8), so Terraform and ArgoCD
# agree on exactly what's installed.
resource "helm_release" "argocd" {
  count = var.fetch_kubeconfig ? 1 : 0

  # When letsencrypt_email is null, letsencrypt_issuer has count=0 and this
  # depends_on is a no-op. Otherwise we wait for the issuer so the ingress
  # can request a cert immediately after install.
  depends_on = [kubectl_manifest.letsencrypt_issuer]

  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  chart = local.argocd_chart_path

  # Read the native YAML file — same file `helm install -f` would use,
  # same file ArgoCD reconciles later.
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

# ArgoCD Application that points back at this repo, managing the ArgoCD
# installation as GitOps. After this applies, any change to
# argocd/argocd/values.yaml in the repo reconciles into the cluster.
#
# kubectl_manifest (not kubernetes_manifest): Application is an ArgoCD CRD
# that only exists after helm_release.argocd installs the chart.
resource "kubectl_manifest" "argocd_self_app" {
  count = var.fetch_kubeconfig ? 1 : 0

  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "argocd"
      namespace = "argocd"
      # Finalizer enables cascading deletion of managed resources when the
      # Application is removed.
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
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })
}

# Optional: SSH deploy key for private forks. Count-gated — if the user
# leaves repo_ssh_private_key_path null, this resource is skipped and
# ArgoCD falls back to anonymous HTTPS (which only works for public forks).
#
# The Secret.data.url field must exactly match the Application's repoURL
# for ArgoCD to pair them — both come from var.argocd_repo_url.
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
