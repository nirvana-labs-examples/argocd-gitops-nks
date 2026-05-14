variable "project_id" {
  description = "Nirvana Labs project ID."
  type        = string
}

variable "region" {
  description = "Nirvana Labs region."
  type        = string
  default     = "us-sva-2"
}

variable "cluster_name" {
  description = "NKS cluster name."
  type        = string
  default     = "argocd-gitops-demo"
}

variable "node_count" {
  description = "Worker node count (single pool)."
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "Worker instance type."
  type        = string
  default     = "n1-highcpu-2"
}

variable "fetch_kubeconfig" {
  description = "Whether to fetch the cluster kubeconfig and install cluster-level resources. Set to true on the second apply, after the control plane is reachable (~5 min after first apply) and you have toggled the public IP on cilium-ingress in the Console."
  type        = bool
  default     = false
}

variable "ingress_public_ip" {
  description = "Public IP of cilium-ingress, obtained after enabling it in the NKS Console. Leave null to fall back to the private VIP (private-only mode — Let's Encrypt HTTP-01 will not work)."
  type        = string
  default     = null
}

variable "argocd_hostname" {
  description = "Optional override for the ArgoCD hostname. Defaults to argocd.<ingress_ip>.nip.io."
  type        = string
  default     = null
}

variable "argocd_repo_url" {
  description = "URL of your fork of argocd-gitops-nks. HTTPS (https://github.com/...) requires no creds for public forks. SSH (git@github.com:...) requires repo_ssh_private_key_path."
  type        = string
}

variable "argocd_repo_branch" {
  description = "Branch that ArgoCD tracks for self-management."
  type        = string
  default     = "main"
}

variable "repo_ssh_private_key_path" {
  description = "Path to an SSH deploy key private key file. Leave null to use public HTTPS without credentials."
  type        = string
  default     = null
}

variable "letsencrypt_email" {
  description = "Email address for Let's Encrypt account registration. Required when ingress_public_ip is set."
  type        = string
  default     = null
}

variable "letsencrypt_acme_server" {
  description = "ACME server URL. Defaults to Let's Encrypt staging — flip to the production URL once you have verified the issuer works."
  type        = string
  default     = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

variable "enable_coredns_hairpin" {
  description = "Install a coredns-custom ConfigMap that resolves the ArgoCD hostname to the private VIP for in-cluster pods. Works around hairpin-NAT on NKS so cert-manager's HTTP-01 self-check succeeds. Only takes effect when ingress_public_ip is set — private-only mode doesn't need split-horizon DNS since the hostname already resolves to the private VIP."
  type        = bool
  default     = true
}
