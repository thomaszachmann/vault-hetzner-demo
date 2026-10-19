# Root-Namespace: Audit, Plattform-Policies, OIDC (Keycloak), Break-Glass

resource "vault_audit" "file" {
  type = "file"
  path = "file"

  # stdout → Pod-Log → Alloy → Loki (zentrale Sicherheitsprotokollierung)
  options = {
    file_path = "stdout"
  }
}

resource "vault_policy" "platform_admin" {
  name   = "platform-admin"
  policy = <<-EOT
    # Plattform-Administration (über OIDC-Gruppe vault-admins, mit MFA in Keycloak)
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
    }
  EOT
}

resource "vault_policy" "breakglass" {
  name   = "breakglass"
  policy = vault_policy.platform_admin.policy
}

# Kurzlebiges Token für Plattformautomatisierung (deploy/failover-Skripte, TTL 8h)
resource "vault_policy" "platform_automation" {
  name   = "platform-automation"
  policy = vault_policy.platform_admin.policy
}

# DR-Operation-Batch-Token: darf ausschließlich den DR-Secondary befördern
resource "vault_policy" "dr_promotion" {
  count = var.enterprise ? 1 : 0

  name   = "dr-secondary-promotion"
  policy = <<-EOT
    path "sys/replication/dr/secondary/promote" {
      capabilities = ["update"]
    }
    path "sys/replication/dr/secondary/update-primary" {
      capabilities = ["update"]
    }
    path "sys/storage/raft/autopilot/state" {
      capabilities = ["update", "read"]
    }
  EOT
}

# ---------------------------------------------------------------------------
# OIDC gegen Keycloak (steht für das zentrale behördliche IdM)
# ---------------------------------------------------------------------------
resource "vault_jwt_auth_backend" "oidc" {
  type                  = "oidc"
  path                  = "oidc"
  description           = "Behörden-IdM (Keycloak) – Menschen, MFA erzwingt Keycloak"
  oidc_discovery_url    = "https://keycloak.${var.services_ip}.nip.io/realms/behoerde"
  oidc_discovery_ca_pem = file(var.ca_cert_file)
  oidc_client_id        = "vault"
  oidc_client_secret    = trimspace(file("${var.secrets_dir}/passwords/keycloak_vault_client"))
  default_role          = "behoerde"

  tune {
    listing_visibility = "unauth"
    default_lease_ttl  = "1h"
    max_lease_ttl      = "8h"
  }
}

resource "vault_jwt_auth_backend_role" "behoerde" {
  backend         = vault_jwt_auth_backend.oidc.path
  role_name       = "behoerde"
  role_type       = "oidc"
  user_claim      = "preferred_username"
  groups_claim    = "groups"
  bound_audiences = ["vault"]
  oidc_scopes     = ["profile", "email"]
  allowed_redirect_uris = concat(
    [for site, ip in var.lb_ips : "https://vault-${site}.${ip}.nip.io:8200/ui/vault/auth/oidc/oidc/callback"],
    ["http://localhost:8250/oidc/callback"],
  )
  token_policies = ["default"]
  token_ttl      = 3600
  token_max_ttl  = 28800
}

# Externe Gruppen = Keycloak-Gruppen. Rechte in den Mandanten-Namespaces werden dort
# über interne Gruppen vergeben, die diese Root-Gruppen als Mitglied haben.
locals {
  idm_groups = {
    "vault-admins"  = ["platform-admin"]
    "fa-entwickler" = var.enterprise ? [] : ["fa-entwickler"]
    "fb-betrieb"    = var.enterprise ? [] : ["fb-betrieb"]
  }
}

resource "vault_identity_group" "idm" {
  for_each = local.idm_groups

  name     = each.key
  type     = "external"
  policies = each.value
}

resource "vault_identity_group_alias" "idm" {
  for_each = local.idm_groups

  name           = each.key
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_group.idm[each.key].id
}

# ---------------------------------------------------------------------------
# Break-Glass: lokaler Notfallzugang, falls das IdM nicht erreichbar ist.
# Jede Nutzung muss im Audit-Log auffallen (Grafana: auth_display_name=userpass-breakglass).
# ---------------------------------------------------------------------------
resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  path        = "breakglass"
  description = "Notfallzugang – nur bei Ausfall des IdM"
}

resource "random_password" "breakglass" {
  length  = 32
  special = false
}

resource "vault_generic_endpoint" "breakglass_user" {
  path                 = "auth/${vault_auth_backend.userpass.path}/users/breakglass"
  ignore_absent_fields = true
  disable_read         = true

  data_json = jsonencode({
    password       = random_password.breakglass.result
    token_policies = [vault_policy.breakglass.name]
    token_ttl      = "30m"
    token_max_ttl  = "1h"
  })
}
