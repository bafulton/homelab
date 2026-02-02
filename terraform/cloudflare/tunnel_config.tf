# Tunnel ingress configuration - only allow public domains
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config {
    # Root domains for public domains
    dynamic "ingress_rule" {
      for_each = var.public_domains
      content {
        hostname = ingress_rule.value
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }
    }

    # Wildcard subdomains for public domains
    dynamic "ingress_rule" {
      for_each = var.public_domains
      content {
        hostname = "*.${ingress_rule.value}"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }
    }

    # Catch-all: reject everything else (required by Cloudflare)
    ingress_rule {
      service = "http_status:404"
    }
  }
}
