# Tunnel ingress configuration - only allow public domains
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config {
    # Public subdomains - specific subdomains from any domain
    # Must come before wildcard rules for proper matching
    dynamic "ingress_rule" {
      for_each = local.public_subdomains
      content {
        hostname = "${ingress_rule.value.subdomain}.${ingress_rule.value.domain}"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }
    }

    # Root domains for wildcard public domains
    dynamic "ingress_rule" {
      for_each = local.wildcard_public_domains
      content {
        hostname = ingress_rule.value.domain
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }
    }

    # Wildcard subdomains for wildcard public domains
    dynamic "ingress_rule" {
      for_each = local.wildcard_public_domains
      content {
        hostname = "*.${ingress_rule.value.domain}"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }
    }

    # Catch-all: reject everything else (required by Cloudflare)
    ingress_rule {
      service = "http_status:404"
    }
  }
}
