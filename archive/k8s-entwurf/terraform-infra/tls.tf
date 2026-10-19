# Server-Zertifikate, signiert von der Offline-Root-CA (scripts/ca-init.sh).
# Namen: nip.io löst <name>.<ip>.nip.io auf <ip> auf – auch für private IPs.
# Let's Encrypt scheidet aus, weil kein Dienst öffentlich erreichbar ist.

locals {
  ca_cert_pem = file("${var.ca_dir}/root-ca.pem")
  ca_key_pem  = file("${var.ca_dir}/root-ca.key")
  pki_out     = "${path.module}/../../.secrets/pki"

  services_site = one([for k, v in var.sites : k if v.services])
  services_lb   = var.sites[local.services_site].lb_ip


  certs = merge(
    {
      for site, cfg in var.sites : "vault-${site}" => {
        cn = "vault-${site}.${cfg.lb_ip}.nip.io"
        dns = concat(
          ["vault-${site}.${cfg.lb_ip}.nip.io", "localhost"],
          flatten([for svc in ["vault", "vault-active", "vault-standby", "vault-internal"] : [
            svc, "${svc}.vault", "${svc}.vault.svc", "${svc}.vault.svc.cluster.local",
          ]]),
          ["*.vault-internal", "*.vault-internal.vault.svc", "*.vault-internal.vault.svc.cluster.local"],
        )
        ips = [cfg.lb_ip, "127.0.0.1"]
      }
    },
    {
      for site, cfg in var.sites : "unseal-${site}" => {
        cn  = "vault-unseal.vault-unseal.svc"
        dns = ["vault-unseal", "vault-unseal.vault-unseal", "vault-unseal.vault-unseal.svc", "vault-unseal.vault-unseal.svc.cluster.local", "localhost"]
        ips = ["127.0.0.1"]
      }
    },
    {
      ingress = {
        cn  = "keycloak.${local.services_lb}.nip.io"
        dns = [for h in ["keycloak", "grafana", "prometheus", "loki"] : "${h}.${local.services_lb}.nip.io"]
        ips = [local.services_lb]
      }
    },
  )
}

resource "tls_private_key" "cert" {
  for_each = local.certs

  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "cert" {
  for_each = local.certs

  private_key_pem = tls_private_key.cert[each.key].private_key_pem
  dns_names       = each.value.dns
  ip_addresses    = each.value.ips

  subject {
    common_name  = each.value.cn
    organization = "Vault Demo Behoerde"
  }
}

resource "tls_locally_signed_cert" "cert" {
  for_each = local.certs

  cert_request_pem      = tls_cert_request.cert[each.key].cert_request_pem
  ca_private_key_pem    = local.ca_key_pem
  ca_cert_pem           = local.ca_cert_pem
  validity_period_hours = 24 * 90
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth", "client_auth"]
}

# Für die Kubernetes-Secrets ablegen (.secrets ist gitignored)
resource "local_file" "cert" {
  for_each = local.certs

  filename        = "${local.pki_out}/${each.key}.crt"
  content         = tls_locally_signed_cert.cert[each.key].cert_pem
  file_permission = "0644"
}

resource "local_sensitive_file" "key" {
  for_each = local.certs

  filename        = "${local.pki_out}/${each.key}.key"
  content         = tls_private_key.cert[each.key].private_key_pem
  file_permission = "0600"
}
