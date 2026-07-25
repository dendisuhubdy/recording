terraform {
  # 1.5.7 is the last MPL-licensed Terraform release and is what's installed
  # here; nothing in this config needs a later version. OpenTofu also works.
  required_version = ">= 1.5"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

data "digitalocean_ssh_key" "deploy" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "web" {
  name      = "summly-web"
  image     = "ubuntu-24-04-x64"
  region    = var.region
  size      = var.size
  ssh_keys  = [data.digitalocean_ssh_key.deploy.id]
  user_data = file("${path.module}/cloud-init.yaml")

  # Static files are redeployed by rsync, so the droplet holds no unique state.
  # Losing it costs a `terraform apply`, not data.
  backups    = false
  monitoring = true

  tags = ["summly"]
}

resource "digitalocean_firewall" "web" {
  name        = "summly-web"
  droplet_ids = [digitalocean_droplet.web.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Egress is needed for apt and Let's Encrypt.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# No DNS resources here on purpose. summly.xyz uses Cloudflare nameservers, so
# DigitalOcean DNS records would never be consulted — creating them would look
# like it worked while doing nothing. The A record is created in Cloudflare;
# see the DNS section of the plan.
