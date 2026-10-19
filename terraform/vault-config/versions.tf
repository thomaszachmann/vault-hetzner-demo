terraform {
  required_version = ">= 1.9"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

# Token kommt aus VAULT_TOKEN (scripts/deploy.sh); Zugriff über SSH-Tunnel auf 127.0.0.1.
provider "vault" {
  address          = var.vault_addr
  ca_cert_file     = var.ca_cert_file
  skip_child_token = true
}
