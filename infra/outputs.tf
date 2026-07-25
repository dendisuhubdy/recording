output "droplet_ip" {
  description = "Public IPv4 address. Used by scripts/deploy-site.sh and the Cloudflare A record."
  value       = digitalocean_droplet.web.ipv4_address
}

output "ssh_command" {
  description = "Convenience command for logging in."
  value       = "ssh -i ~/.ssh/id_ed25519_DO root@${digitalocean_droplet.web.ipv4_address}"
}
