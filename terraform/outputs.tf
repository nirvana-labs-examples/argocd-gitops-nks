output "cluster_id" {
  description = "ID of the NKS cluster."
  value       = module.nks.cluster_id
}

output "cluster_public_ip" {
  description = "Public IP of the Kubernetes API server VIP (not the ingress — see ingress_public_ip)."
  value       = module.nks.cluster_public_ip
}

output "ingress_vip" {
  description = "Private IP of the shared ingress VIP."
  value       = module.nks.ingress_vip
}

output "kubeconfig_path" {
  description = "Path to the written kubeconfig file. Null until fetch_kubeconfig is true."
  value       = module.nks.kubeconfig_path
}

output "argocd_url" {
  description = "URL to reach the ArgoCD UI (once the second apply completes)."
  value       = var.fetch_kubeconfig ? "https://${local.argocd_hostname}" : "pending — set fetch_kubeconfig=true and re-apply"
}

output "argocd_password_cmd" {
  description = "Command to read the initial admin password. Null until fetch_kubeconfig is true."
  value = module.nks.kubeconfig_path != null ? (
    "kubectl --kubeconfig ${module.nks.kubeconfig_path} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
  ) : null
}

output "next_steps" {
  description = "What to do after this apply."
  value = var.fetch_kubeconfig ? (<<-EOT
ArgoCD URL: https://${local.argocd_hostname}
Login:      admin
Password:   terraform output -raw argocd_password_cmd | sh

(If the page doesn't load, give cert-manager 1-2 minutes to issue the cert.)
EOT
    ) : (<<-EOT
First apply complete. Cluster is provisioning.

1. Wait ~10 minutes for the control plane to come up and cilium-ingress to appear in the dashboard.
2. Go to the Nirvana Console → Clusters → ${var.cluster_name} → Load Balancers
   tab → ⋮ menu next to cilium-ingress → Enable Public IP. Copy the IP.
3. Set these env vars:
     export TF_VAR_ingress_public_ip=<that IP>
     export TF_VAR_letsencrypt_email=<your email>
     export TF_VAR_fetch_kubeconfig=true
4. terraform apply again.
EOT
  )
}
