variable "do_token" {
  description = "DigitalOcean API token. Set via TF_VAR_do_token, never in a file."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "sgp1"
}

variable "size" {
  description = "Droplet size. This serves static files; the smallest tier is sufficient."
  type        = string
  default     = "s-1vcpu-512mb-10gb"
}

variable "ssh_key_name" {
  description = <<-EOT
    Name of the SSH key already uploaded to DigitalOcean. Defaults to
    "peptidebay-do", which is the account's name for the key whose private half
    is at ~/.ssh/id_ed25519_DO (verified by matching MD5 fingerprint).
  EOT
  type        = string
  default     = "peptidebay-do"
}
