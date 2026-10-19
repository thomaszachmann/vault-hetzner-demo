locals {
  network_cidr = "10.0.0.0/16"
  shared_cidr  = "10.0.0.0/24"
  gateway_ip   = "10.0.0.1" # Hetzner-Netzwerk-Gateway (erste IP des Netzes)
  bastion_ip   = "10.0.0.2"
  services_ip  = "10.0.0.10"

  # Feste NodePorts, auf die die Hetzner-LBs zeigen (kein Cloud-Controller im Cluster nötig)
  node_ports = {
    vault_api     = 30200
    vault_cluster = 30201
  }

  # k3s-fsn1-1 … k3s-nbg1-3 mit festen IPs .11, .12, .13 im Standort-Subnetz
  nodes = merge([
    for site, cfg in var.sites : {
      for i in range(1, var.nodes_per_site + 1) :
      "k3s-${site}-${i}" => {
        site        = site
        location    = cfg.location
        server_type = cfg.server_type
        index       = i
        ip          = cidrhost(cfg.subnet, 10 + i)
        first_ip    = cidrhost(cfg.subnet, 11)
      }
    }
  ]...)

  common_labels = {
    project = var.name_prefix
  }
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.name_prefix}-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
  labels     = local.common_labels
}

# ---------------------------------------------------------------------------
# Netzwerk: ein Hetzner-Netz, ein Subnetz je Standort
# ---------------------------------------------------------------------------
resource "hcloud_network" "main" {
  name     = var.name_prefix
  ip_range = local.network_cidr
  labels   = local.common_labels
}

resource "hcloud_network_subnet" "shared" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = local.shared_cidr
}

resource "hcloud_network_subnet" "site" {
  for_each = var.sites

  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = each.value.subnet
}

# Alle Server ohne öffentliche IP gehen über die Bastion (NAT) ins Internet.
resource "hcloud_network_route" "default_via_bastion" {
  network_id  = hcloud_network.main.id
  destination = "0.0.0.0/0"
  gateway     = local.bastion_ip

  depends_on = [hcloud_server.bastion]
}

# ---------------------------------------------------------------------------
# Bastion: einziger Server mit öffentlicher IP (SSH, WireGuard, NAT-Gateway)
# ---------------------------------------------------------------------------
resource "hcloud_firewall" "bastion" {
  name   = "${var.name_prefix}-bastion"
  labels = local.common_labels

  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_cidrs
  }

  rule {
    description = "WireGuard"
    direction   = "in"
    protocol    = "udp"
    port        = "51820"
    source_ips  = var.admin_cidrs
  }

  rule {
    description = "ICMP"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "bastion" {
  name         = "${var.name_prefix}-bastion"
  server_type  = var.bastion_server_type
  image        = var.image
  location     = var.shared_location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.bastion.id]
  labels       = merge(local.common_labels, { role = "bastion" })
  user_data    = templatefile("${path.module}/templates/cloud-init-bastion.yaml", { network_cidr = local.network_cidr })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.bastion_ip
  }

  depends_on = [hcloud_network_subnet.shared]
}

# ---------------------------------------------------------------------------
# Externe Dienste (stellvertretend für behördliche Infrastruktur):
# Keycloak (IdM), PostgreSQL, Prometheus, Grafana, Loki – nur privat erreichbar.
# ---------------------------------------------------------------------------
resource "hcloud_server" "services" {
  name        = "${var.name_prefix}-services"
  server_type = var.services_server_type
  image       = var.image
  location    = var.shared_location
  ssh_keys    = [hcloud_ssh_key.admin.id]
  labels      = merge(local.common_labels, { role = "services" })
  user_data   = templatefile("${path.module}/templates/cloud-init-private.yaml", { gateway_ip = local.gateway_ip })

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = local.services_ip
  }

  depends_on = [hcloud_network_subnet.shared, hcloud_network_route.default_via_bastion]
}

# ---------------------------------------------------------------------------
# k3s-Cluster je Standort: 3 Server-Nodes (embedded etcd), nur privates Netz.
# Spread-Placement-Group = unterschiedliche physische Hosts ("Failure Domains").
# ---------------------------------------------------------------------------
resource "random_password" "k3s_token" {
  for_each = var.sites

  length  = 48
  special = false
}

resource "hcloud_placement_group" "site" {
  for_each = var.sites

  name   = "${var.name_prefix}-${each.key}"
  type   = "spread"
  labels = local.common_labels
}

resource "hcloud_server" "k3s" {
  for_each = local.nodes

  name               = each.key
  server_type        = each.value.server_type
  image              = var.image
  location           = each.value.location
  placement_group_id = hcloud_placement_group.site[each.value.site].id
  ssh_keys           = [hcloud_ssh_key.admin.id]
  labels             = merge(local.common_labels, { role = "k3s", site = each.value.site })

  user_data = templatefile("${path.module}/templates/cloud-init-k3s.yaml", {
    gateway_ip  = local.gateway_ip
    k3s_version = var.k3s_version
    k3s_token   = random_password.k3s_token[each.value.site].result
    node_ip     = each.value.ip
    first_ip    = each.value.first_ip
    is_first    = each.value.index == 1
    site        = each.value.site
    node_ports  = local.node_ports
  })

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.main.id
    ip         = each.value.ip
  }

  depends_on = [hcloud_network_subnet.site, hcloud_network_route.default_via_bastion]
}

# ---------------------------------------------------------------------------
# Interne Load Balancer je Standort: nur privates Interface, TCP-Passthrough
# auf feste NodePorts. TLS terminiert Ende-zu-Ende in Vault bzw. im Ingress.
# ---------------------------------------------------------------------------
resource "hcloud_load_balancer" "site" {
  for_each = var.sites

  name               = "${var.name_prefix}-${each.key}"
  load_balancer_type = "lb11"
  location           = each.value.location
  labels             = local.common_labels
}

resource "hcloud_load_balancer_network" "site" {
  for_each = var.sites

  load_balancer_id        = hcloud_load_balancer.site[each.key].id
  network_id              = hcloud_network.main.id
  ip                      = each.value.lb_ip
  enable_public_interface = false

  depends_on = [hcloud_network_subnet.site]
}

resource "hcloud_load_balancer_target" "site" {
  for_each = var.sites

  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.site[each.key].id
  label_selector   = "role=k3s,site=${each.key}"
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.site]
}

resource "hcloud_load_balancer_service" "vault_api" {
  for_each = var.sites

  load_balancer_id = hcloud_load_balancer.site[each.key].id
  protocol         = "tcp"
  listen_port      = 8200
  destination_port = local.node_ports.vault_api

  health_check {
    protocol = "http"
    port     = local.node_ports.vault_api
    interval = 5
    timeout  = 3
    retries  = 2

    http {
      # Active, Standby und DR-Secondary gelten als gesund
      path         = "/v1/sys/health?standbyok=true&perfstandbyok=true&drsecondarycode=200"
      tls          = true
      status_codes = ["200"]
    }
  }
}

# Replikation (DR) zwischen den Standorten: Cluster-Port des aktiven Vault-Pods
resource "hcloud_load_balancer_service" "vault_cluster" {
  for_each = var.sites

  load_balancer_id = hcloud_load_balancer.site[each.key].id
  protocol         = "tcp"
  listen_port      = 8201
  destination_port = local.node_ports.vault_cluster

  health_check {
    protocol = "tcp"
    port     = local.node_ports.vault_cluster
    interval = 5
    timeout  = 3
    retries  = 2
  }
}

# Kubernetes-API je Standort über den LB – kubectl bleibt erreichbar, egal welcher Node ausfällt
resource "hcloud_load_balancer_service" "kube_api" {
  for_each = var.sites

  load_balancer_id = hcloud_load_balancer.site[each.key].id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 5
    timeout  = 3
    retries  = 2
  }
}
