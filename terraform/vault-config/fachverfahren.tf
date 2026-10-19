# KV v2 in den Fachverfahren – zeigt Versionierung und Mandantentrennung:
#   bob   (fa-entwickler) → fachverfahren-a/development: lesen/schreiben
#                          → fachverfahren-a/production: kein Zugriff
#   carol (fb-betrieb)    → fachverfahren-b/production: lesen/schreiben
#   bob sieht fachverfahren-b überhaupt nicht.

locals {
  fa_dev  = local.tenants["fachverfahren-a/development"]
  fa_prod = local.tenants["fachverfahren-a/production"]
  fb_prod = local.tenants["fachverfahren-b/production"]

  kv_tenants = {
    "fachverfahren-a/development" = {
      secrets = {
        "app-config" = { db_host = "db.fa-dev.behoerde.demo", log_level = "debug", feature_x = "on" }
        "ext-api"    = { endpoint = "https://api.melderegister.demo/v2", api_key = "demo-${random_password.kv["fa-dev"].result}" }
      }
    }
    "fachverfahren-a/production" = {
      secrets = {
        "app-config" = { db_host = "db.fa-prod.behoerde.demo", log_level = "warn", feature_x = "off" }
        "ext-api"    = { endpoint = "https://api.melderegister.demo/v2", api_key = "demo-${random_password.kv["fa-prod"].result}" }
      }
    }
    "fachverfahren-b/production" = {
      secrets = {
        "app-config" = { db_host = "db.fb-prod.behoerde.demo", log_level = "info" }
        "smtp"       = { host = "smtp.behoerde.demo", user = "fb-noreply", password = random_password.kv["fb-prod"].result }
      }
    }
  }

  kv_secrets = merge([
    for t, cfg in local.kv_tenants : {
      for name, data in cfg.secrets : "${t}:${name}" => { tenant = t, name = name, data = data }
    }
  ]...)
}

resource "random_password" "kv" {
  for_each = toset(["fa-dev", "fa-prod", "fb-prod"])

  length  = 24
  special = false
}

resource "vault_mount" "kv" {
  for_each = local.kv_tenants

  namespace   = local.tenants[each.key].namespace
  path        = "${local.tenants[each.key].prefix}kv"
  type        = "kv"
  options     = { version = "2" }
  description = "Statische Secrets ${each.key}"

  depends_on = [vault_namespace.child]
}

resource "vault_kv_secret_v2" "seed" {
  for_each = local.kv_secrets

  namespace = local.tenants[each.value.tenant].namespace
  mount     = vault_mount.kv[each.value.tenant].path
  name      = each.value.name
  data_json = jsonencode(each.value.data)

  lifecycle {
    # Die Demo überschreibt Secrets live (Versionierung) – Terraform soll das nicht zurückdrehen.
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "fa_entwickler" {
  namespace = local.fa_dev.namespace
  name      = "fa-entwickler"
  policy    = <<-EOT
    path "${local.fa_dev.prefix}kv/data/*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list"]
    }
    path "${local.fa_dev.prefix}kv/metadata/*" {
      capabilities = ["read", "list", "delete"]
    }
    path "${local.fa_dev.prefix}kv/undelete/*" {
      capabilities = ["update"]
    }
  EOT

  depends_on = [vault_namespace.child]
}

resource "vault_policy" "fb_betrieb" {
  namespace = local.fb_prod.namespace
  name      = "fb-betrieb"
  policy    = <<-EOT
    path "${local.fb_prod.prefix}kv/data/*" {
      capabilities = ["create", "read", "update", "patch", "list"]
    }
    path "${local.fb_prod.prefix}kv/metadata/*" {
      capabilities = ["read", "list"]
    }
  EOT

  depends_on = [vault_namespace.child]
}

# Enterprise: interne Gruppen im Mandanten-Namespace mit der Root-Gruppe als Mitglied
resource "vault_identity_group" "fa_entwickler" {
  count = var.enterprise ? 1 : 0

  namespace        = local.fa_dev.namespace
  name             = "fa-entwickler"
  type             = "internal"
  policies         = [vault_policy.fa_entwickler.name]
  member_group_ids = [vault_identity_group.idm["fa-entwickler"].id]
}

resource "vault_identity_group" "fb_betrieb" {
  count = var.enterprise ? 1 : 0

  namespace        = local.fb_prod.namespace
  name             = "fb-betrieb"
  type             = "internal"
  policies         = [vault_policy.fb_betrieb.name]
  member_group_ids = [vault_identity_group.idm["fb-betrieb"].id]
}
