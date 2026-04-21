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
