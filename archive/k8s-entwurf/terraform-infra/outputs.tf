output "bastion_ipv4" {
  value = hcloud_server.bastion.ipv4_address
}

output "nodes" {
  value = { for name, n in local.nodes : name => { site = n.site, ip = n.ip, index = n.index } }
}

output "sites" {
  value = {
    for site, cfg in var.sites : site => {
      lb_ip    = cfg.lb_ip
      first_ip = cidrhost(cfg.subnet, 11)
      services = cfg.services
    }
  }
}

output "services_site" {
  value = local.services_site
}

output "node_ports" {
  value = local.node_ports
}
