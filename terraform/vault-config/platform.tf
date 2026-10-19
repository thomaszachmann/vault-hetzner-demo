# platform/shared-services: Transit (Encryption as a Service) und
# Zertifikats-Login für externe Anwendungen (Zertifikat aus zentrale-dienste/certificates).

locals {
  shared = local.tenants["platform/shared-services"]
}

resource "vault_mount" "transit" {
  namespace   = local.shared.namespace
  path        = "${local.shared.prefix}transit"
  type        = "transit"
  description = "Zentraler Kryptodienst – Schlüssel verlassen Vault nie"

  depends_on = [vault_namespace.child]
}

resource "vault_transit_secret_backend_key" "fachdaten" {
  namespace        = local.shared.namespace
  backend          = vault_mount.transit.path
  name             = "fachdaten"
  type             = "aes256-gcm96"
  deletion_allowed = true
}

resource "vault_policy" "transit_anwendung" {
  namespace = local.shared.namespace
  name      = "transit-anwendung"
  policy    = <<-EOT
    path "${local.shared.prefix}transit/encrypt/fachdaten" {
      capabilities = ["update"]
    }
    path "${local.shared.prefix}transit/decrypt/fachdaten" {
      capabilities = ["update"]
    }
    path "${local.shared.prefix}transit/rewrap/fachdaten" {
      capabilities = ["update"]
    }
  EOT

  depends_on = [vault_namespace.child]
}

resource "vault_auth_backend" "cert" {
  namespace   = local.shared.namespace
  type        = "cert"
  path        = "${local.shared.prefix}cert"
  description = "TLS-Client-Zertifikate externer Anwendungen"

  depends_on = [vault_namespace.child]
}

resource "vault_cert_auth_backend_role" "externe_anwendung" {
  namespace            = local.shared.namespace
  backend              = vault_auth_backend.cert.path
  name                 = "externe-anwendung"
  certificate          = tls_locally_signed_cert.issuing.cert_pem
  allowed_common_names = ["*.apps.behoerde.demo"]
  token_policies       = [vault_policy.transit_anwendung.name]
  token_ttl            = 900
  token_max_ttl        = 3600
}
