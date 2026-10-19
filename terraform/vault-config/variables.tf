variable "vault_addr" {
  type    = string
  default = "https://127.0.0.1:18200"
}

variable "secrets_dir" {
  type    = string
  default = "../../.secrets"
}

variable "ca_cert_file" {
  type    = string
  default = "../../.secrets/ca/root-ca.pem"
}

variable "enterprise" {
  description = "true = Namespaces, sonst flache Pfade mit Präfix (Community Edition)"
  type        = bool
}

variable "services_ip" {
  type    = string
  default = "10.0.0.10"
}

variable "lb_ips" {
  type = map(string)
  default = {
    fsn1 = "10.0.1.100"
    nbg1 = "10.0.2.100"
  }
}

variable "app_site" {
  description = "Standort des Anwendungs-Clusters (Kubernetes Auth)"
  type        = string
  default     = "nbg1"
}

variable "k8s_host" {
  description = "Kubernetes-API des Anwendungs-Clusters (aus Sicht der Vault-Pods)"
  type        = string
  default     = "https://10.0.2.11:6443"
}
