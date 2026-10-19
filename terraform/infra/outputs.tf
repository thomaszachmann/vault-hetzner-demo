output "bastion_ipv4" {
  value = hcloud_server.bastion.ipv4_address
}

output "services_ip" {
  value = local.services_ip
}

output "nodes" {
  value = { for name, n in local.nodes : name => { site = n.site, ip = n.ip, index = n.index } }
}

output "sites" {
  value = {
    for site, cfg in var.sites : site => {
      lb_ip = cfg.lb_ip
    }
  }
}

# Ansible-Inventar für die Dienste-VM (Vault selbst wird per Helm installiert)
resource "local_file" "inventory" {
  filename        = "${path.module}/../../ansible/inventory.yml"
  file_permission = "0644"
  content = yamlencode({
    all = {
      vars = {
        ansible_user            = "root"
        ansible_ssh_common_args = "-o ProxyCommand=\"ssh -W %h:%p -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@${hcloud_server.bastion.ipv4_address}\""
        bastion_ip              = local.bastion_ip
        services_ip             = local.services_ip
        network_cidr            = local.network_cidr
        site_subnets            = { for site, cfg in var.sites : site => cfg.subnet }
        lb_ips                  = { for site, cfg in var.sites : site => cfg.lb_ip }
      }
      children = {
        services = {
          hosts = {
            services = { ansible_host = local.services_ip }
          }
        }
      }
    }
  })
}
