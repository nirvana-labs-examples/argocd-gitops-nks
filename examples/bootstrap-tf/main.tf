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
