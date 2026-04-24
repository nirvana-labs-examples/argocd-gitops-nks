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

# Pre-create the argocd namespace as its own resource so cluster RBAC grants
# access to it before helm_release runs its preflight checks. Creating the
# namespace via helm_release's create_namespace attribute is too late —
# helm tries to read existing release secrets first and fails on clusters
# where secret access is namespace-scoped.
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

# ArgoCD installed by Terraform. After it comes up, the cert-manager
# Application (below) syncs the wrapper chart from this repo — which
# includes the Let's Encrypt ClusterIssuer in its templates.
resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace.argocd]

  name      = "argocd"
  namespace = kubernetes_namespace.argocd.metadata[0].name

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

  # After the initial install, ArgoCD self-manages via the Application CR
  # below — it reconciles argocd/argocd/ from your fork. Ignoring values/set
  # here prevents Terraform from fighting with ArgoCD on subsequent applies
  # when `values.yaml` changes. The release itself still needs to exist so
  # Terraform can destroy it on `terraform destroy`.
  lifecycle {
    ignore_changes = [
      values,
      set,
      version,
    ]
  }
}

# CoreDNS hairpin-NAT workaround. Let's Encrypt HTTP-01 self-check runs
# from cert-manager pods — those pods can't reach the cluster's own public
# IP on NKS (no NAT hairpin). This split-horizon record resolves the
# ArgoCD hostname to the private ingress VIP for in-cluster pods, so the
# self-check skips the public round-trip. Let's Encrypt's external
# validator still hits the public path unchanged.
#
# Not needed when ingress_public_ip is null (private-only): the hostname
# resolves to the private VIP directly via nip.io and there's no public
# path to hairpin around.
#
# CoreDNS on NKS imports `coredns-custom` by default (Corefile contains
# `import /etc/coredns/custom/*.server`), so the ConfigMap is picked up
# automatically without restarting CoreDNS.
resource "kubernetes_config_map" "coredns_hairpin" {
  count = var.enable_coredns_hairpin && var.ingress_public_ip != null ? 1 : 0

  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
  }

  data = {
    "hairpin.server" = <<-EOT
      ${local.argocd_hostname} {
          hosts {
              ${module.nks.ingress_vip} ${local.argocd_hostname}
              fallthrough
          }
          forward . /etc/resolv.conf
      }
    EOT
  }
}

# Self-management Application: ArgoCD reconciles argocd/argocd/ from the
# fork so future changes to values.yaml don't require Terraform.
resource "kubectl_manifest" "argocd_self_app" {
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

# cert-manager as an ArgoCD Application. Points at argocd/cert-manager/
# wrapper chart, which installs cert-manager via a dependency on the jetstack
# chart AND applies a ClusterIssuer from its own templates/ once the
# cert-manager CRDs are registered. Skipped when letsencrypt_email is null.
resource "kubectl_manifest" "cert_manager_app" {
  count = var.letsencrypt_email != null ? 1 : 0

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

# Optional: SSH deploy key for private forks.
resource "kubernetes_secret" "argocd_repo" {
  count = var.repo_ssh_private_key_path != null ? 1 : 0

  depends_on = [kubernetes_namespace.argocd]

  metadata {
    name      = "argocd-repo"
    namespace = kubernetes_namespace.argocd.metadata[0].name
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
