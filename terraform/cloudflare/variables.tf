# Public domains - have public DNS records pointing to Cloudflare Tunnel
variable "public_domains" {
  type = map(string)
  default = {
    "yak-shave-com"     = "yak-shave.com"
    "benfulton-me"      = "benfulton.me"
    "fultonhuffman-com" = "fultonhuffman.com"
  }
  description = "Domains that should have public DNS records via Cloudflare Tunnel"
}

# Private domains - no public DNS records (Tailscale-only)
variable "private_domains" {
  type = map(string)
  default = {
    "catfish-mountain-com" = "catfish-mountain.com"
  }
  description = "Domains that should NOT have public DNS records (internal/Tailscale-only)"
}

# All domains combined (for zone lookups)
locals {
  all_domains = merge(var.public_domains, var.private_domains)
}
