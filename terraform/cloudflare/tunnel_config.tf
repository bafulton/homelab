# Tunnel ingress configuration - all traffic routes to Traefik
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config {
    # Catch-all rule: route everything to Traefik
    ingress_rule {
      service = "http://traefik.traefik.svc.cluster.local:80"
    }
  }
}
