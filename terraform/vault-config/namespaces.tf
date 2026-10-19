# Mandantenstruktur: Plattform, Fachverfahren und zentrale Dienste je als eigener Namespace.
# Enterprise: echte Namespaces. Community: dieselben Engines im Root, Pfad mit Präfix
# (z. B. "fachverfahren-a-development-kv/"), damit die Demo auch ohne Lizenz läuft.

locals {
  namespace_tree = {
    "platform"         = ["infrastructure", "security", "shared-services"]
    "fachverfahren-a"  = ["development", "staging", "production"]
    "fachverfahren-b"  = ["development", "staging", "production"]
    "zentrale-dienste" = ["cicd", "database", "certificates"]
  }

  child_namespaces = merge([
    for parent, children in local.namespace_tree : {
      for child in children : "${parent}/${child}" => { parent = parent, child = child }
    }
  ]...)

  # Für jeden genutzten Mandanten: Namespace (oder null) und Mount-Präfix
  tenants = {
    for p in [
      "fachverfahren-a/development",
      "fachverfahren-a/production",
      "fachverfahren-b/production",
      "zentrale-dienste/database",
      "zentrale-dienste/certificates",
      "platform/shared-services",
      ] : p => {
      namespace = var.enterprise ? p : null
      prefix    = var.enterprise ? "" : "${replace(p, "/", "-")}-"
      # Voller API-Pfad-Präfix aus Sicht des Root-Namespace
      api = var.enterprise ? "${p}/" : "${replace(p, "/", "-")}-"
    }
  }
}

resource "vault_namespace" "parent" {
  for_each = var.enterprise ? local.namespace_tree : {}

  path = each.key
}

resource "vault_namespace" "child" {
  for_each = var.enterprise ? local.child_namespaces : {}

  namespace = vault_namespace.parent[each.value.parent].path
  path      = each.value.child
}
