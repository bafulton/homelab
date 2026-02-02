# Domain configuration - unified structure for all domains
# - wildcard_public: true = wildcard DNS (*.domain.com) routes to tunnel (public services)
# - wildcard_public: false = no wildcard DNS (private, Tailscale Split DNS only)
# - public_subdomains: specific subdomains that are public (e.g., webhooks)
variable "domains" {
  type = map(object({
    domain            = string
    wildcard_public   = bool
    public_subdomains = set(string)
  }))
  default = {
    "yak-shave-com" = {
      domain            = "yak-shave.com"
      wildcard_public   = true
      public_subdomains = []
    }
    "benfulton-me" = {
      domain            = "benfulton.me"
      wildcard_public   = true
      public_subdomains = []
    }
    "fultonhuffman-com" = {
      domain            = "fultonhuffman.com"
      wildcard_public   = true
      public_subdomains = []
    }
    "catfish-mountain-com" = {
      domain            = "catfish-mountain.com"
      wildcard_public   = false  # Private by default (Tailscale Split DNS)
      public_subdomains = [
        "argocd-webhook"  # GitHub webhook needs public access
      ]
    }
  }
  description = "Domain configuration: wildcard_public controls wildcard DNS, public_subdomains for specific exceptions"
}

# Computed locals from domain configuration
locals {
  # All domains (for zone lookups)
  all_domains = { for k, v in var.domains : k => v.domain }

  # Domains with wildcard public DNS
  wildcard_public_domains = { for k, v in var.domains : k => v if v.wildcard_public }

  # All public subdomains (flattened for DNS records and tunnel rules)
  public_subdomains = merge([
    for domain_key, config in var.domains : {
      for subdomain in config.public_subdomains :
      "${domain_key}-${subdomain}" => {
        domain    = config.domain
        subdomain = subdomain
      }
    }
  ]...)
}
