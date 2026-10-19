# ---------------------------------------------------------------------------
# zentrale-dienste/database: dynamische PostgreSQL-Zugänge mit TTL
# ---------------------------------------------------------------------------
locals {
  db  = local.tenants["zentrale-dienste/database"]
  pki = local.tenants["zentrale-dienste/certificates"]
}

resource "vault_mount" "database" {
  namespace   = local.db.namespace
  path        = "${local.db.prefix}database"
  type        = "database"
  description = "Dynamische Datenbank-Zugänge"

  depends_on = [vault_namespace.child]
}

resource "vault_database_secret_backend_connection" "fachverfahren" {
  namespace     = local.db.namespace
  backend       = vault_mount.database.path
  name          = "fachverfahren"
  allowed_roles = ["fachverfahren-lesen"]

  postgresql {
    # Demo ohne TLS zur DB – in Produktion sslmode=verify-full
    connection_url = "postgresql://{{username}}:{{password}}@${var.services_ip}:5432/fachverfahren?sslmode=disable"
    username       = "vault"
    password       = trimspace(file("${var.secrets_dir}/passwords/postgres_vault"))
  }

  lifecycle {
    # Nach `vault write database/rotate-root/fachverfahren` kennt nur noch Vault das Passwort.
    ignore_changes = [postgresql[0].password]
  }
}

resource "vault_database_secret_backend_role" "fachverfahren_lesen" {
  namespace = local.db.namespace
  backend   = vault_mount.database.path
  name      = "fachverfahren-lesen"
  db_name   = vault_database_secret_backend_connection.fachverfahren.name

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]
  default_ttl = 300
  max_ttl     = 3600
}

resource "vault_policy" "db_fachverfahren" {
  namespace = local.db.namespace
  name      = "db-fachverfahren-lesen"
  policy    = <<-EOT
    path "${local.db.prefix}database/creds/fachverfahren-lesen" {
      capabilities = ["read"]
    }
  EOT

  depends_on = [vault_namespace.child]
}

# Kubernetes Auth für die Fachanwendung im nbg1-Cluster: Vault prüft das
# Service-Account-Token über die TokenReview-API dieses Clusters.
resource "vault_auth_backend" "kubernetes" {
  namespace   = local.db.namespace
  type        = "kubernetes"
  path        = "${local.db.prefix}kubernetes"
  description = "Workloads im Anwendungs-Cluster (nbg1)"

  depends_on = [vault_namespace.child]
}

resource "vault_kubernetes_auth_backend_config" "app_cluster" {
  namespace          = local.db.namespace
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = var.k8s_host
  kubernetes_ca_cert = file("${var.secrets_dir}/k8s-${var.app_site}-ca.crt")
  token_reviewer_jwt = file("${var.secrets_dir}/k8s-${var.app_site}-reviewer.jwt")
}

resource "vault_kubernetes_auth_backend_role" "fachanwendung" {
  namespace                        = local.db.namespace
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "fachanwendung"
  bound_service_account_names      = ["fachanwendung"]
  bound_service_account_namespaces = ["fachanwendung"]
  token_policies                   = [vault_policy.db_fachverfahren.name]
  token_ttl                        = 3600
  token_max_ttl                    = 14400

  depends_on = [vault_kubernetes_auth_backend_config.app_cluster]
}

# ---------------------------------------------------------------------------
# zentrale-dienste/certificates: Intermediate CA unterhalb der Offline-Root-CA
# Die Root-CA (behördliche PKI) signiert offline – Vault erhält nur die Intermediate.
# ---------------------------------------------------------------------------
resource "vault_mount" "pki" {
  namespace                 = local.pki.namespace
  path                      = "${local.pki.prefix}pki"
  type                      = "pki"
  description               = "Issuing CA für interne Dienste und externe Anwendungen"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 63072000

  depends_on = [vault_namespace.child]
}

resource "vault_pki_secret_backend_intermediate_cert_request" "issuing" {
  namespace    = local.pki.namespace
  backend      = vault_mount.pki.path
  type         = "internal"
  common_name  = "Vault Demo Issuing CA"
  organization = "Vault Demo Behoerde"
  key_type     = "ec"
  key_bits     = 384
}

resource "tls_locally_signed_cert" "issuing" {
  cert_request_pem      = vault_pki_secret_backend_intermediate_cert_request.issuing.csr
  ca_private_key_pem    = file("${var.secrets_dir}/ca/root-ca.key")
  ca_cert_pem           = file(var.ca_cert_file)
  is_ca_certificate     = true
  set_subject_key_id    = true
  validity_period_hours = 24 * 365 * 2
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]
}

resource "vault_pki_secret_backend_intermediate_set_signed" "issuing" {
  namespace   = local.pki.namespace
  backend     = vault_mount.pki.path
  certificate = "${tls_locally_signed_cert.issuing.cert_pem}\n${file(var.ca_cert_file)}"
}

resource "vault_pki_secret_backend_config_urls" "pki" {
  namespace               = local.pki.namespace
  backend                 = vault_mount.pki.path
  issuing_certificates    = ["https://vault-fsn1.${var.lb_ips.fsn1}.nip.io:8200/v1/${local.pki.api}pki/ca"]
  crl_distribution_points = ["https://vault-fsn1.${var.lb_ips.fsn1}.nip.io:8200/v1/${local.pki.api}pki/crl"]
}

resource "vault_pki_secret_backend_role" "interne_dienste" {
  namespace        = local.pki.namespace
  backend          = vault_mount.pki.path
  name             = "interne-dienste"
  allowed_domains  = ["svc.behoerde.demo"]
  allow_subdomains = true
  key_type         = "ec"
  key_bits         = 256
  ttl              = 86400
  max_ttl          = 259200
  server_flag      = true
  client_flag      = true

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.issuing]
}

resource "vault_pki_secret_backend_role" "externe_anwendungen" {
  namespace        = local.pki.namespace
  backend          = vault_mount.pki.path
  name             = "externe-anwendungen"
  allowed_domains  = ["apps.behoerde.demo"]
  allow_subdomains = true
  key_type         = "ec"
  key_bits         = 256
  ttl              = 3600
  max_ttl          = 86400
  server_flag      = false
  client_flag      = true

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.issuing]
}
