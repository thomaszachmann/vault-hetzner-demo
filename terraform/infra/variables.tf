variable "name_prefix" {
  description = "Präfix für alle Ressourcen-Namen"
  type        = string
  default     = "vault-demo"
}

variable "ssh_public_key_path" {
  description = "Öffentlicher SSH-Key für den Admin-Zugang"
  type        = string
  default     = "~/.ssh/vault-demo.pub"
}

variable "admin_cidrs" {
  description = "Quell-Netze, die SSH/WireGuard auf der Bastion erreichen dürfen (deploy.sh setzt die aktuelle IP)"
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "image" {
  type    = string
  default = "ubuntu-24.04"
}

variable "k3s_version" {
  type    = string
  default = "v1.36.5+k3s1"
}

variable "bastion_server_type" {
  type    = string
  default = "cpx12"
}

variable "nodes_per_site" {
  description = "k3s-Server-Nodes je Standort (embedded etcd + Vault-Raft brauchen eine ungerade Anzahl)"
  type        = number
  default     = 3

  validation {
    condition     = contains([3, 5], var.nodes_per_site)
    error_message = "3 oder 5 Nodes."
  }
}

# Standort A = Primär (RZ A), Standort B = DR (RZ B). Je Standort ein k3s-Cluster.
variable "sites" {
  type = map(object({
    location    = string
    subnet      = string
    lb_ip       = string
    server_type = string
  }))
  default = {
    fsn1 = { location = "fsn1", subnet = "10.0.1.0/24", lb_ip = "10.0.1.100", server_type = "cpx22" }
    nbg1 = { location = "nbg1", subnet = "10.0.2.0/24", lb_ip = "10.0.2.100", server_type = "cpx22" }
  }
}

variable "services_server_type" {
  description = "Externe Dienste (Keycloak, PostgreSQL, Prometheus, Grafana, Loki)"
  type        = string
  default     = "cpx32"
}

variable "shared_location" {
  description = "Standort von Bastion und externen Diensten – bewusst nicht RZ A, damit beides den Failover übersteht"
  type        = string
  default     = "nbg1"
}

variable "ca_dir" {
  description = "Verzeichnis der Offline-Root-CA (scripts/ca-init.sh)"
  type        = string
  default     = "../../.secrets/ca"
}
