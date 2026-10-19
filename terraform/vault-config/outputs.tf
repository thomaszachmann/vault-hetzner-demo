output "fachanwendung" {
  description = "Werte für die Injector-Annotationen der Fachanwendung"
  value = {
    namespace  = local.db.namespace == null ? "" : local.db.namespace
    k8s_mount  = vault_auth_backend.kubernetes.path
    creds_path = "${local.db.prefix}database/creds/fachverfahren-lesen"
  }
}

output "breakglass_password" {
  value     = random_password.breakglass.result
  sensitive = true
}

output "paths" {
  description = "Volle API-Pfade aus Sicht des Root-Namespace (für Demo-Befehle)"
  value = {
    kv_fa_dev  = "${local.fa_dev.api}kv"
    kv_fa_prod = "${local.fa_prod.api}kv"
    kv_fb_prod = "${local.fb_prod.api}kv"
    database   = "${local.db.api}database"
    pki        = "${local.pki.api}pki"
    transit    = "${local.shared.api}transit"
    cert_auth  = "${local.shared.api}cert"
  }
}
