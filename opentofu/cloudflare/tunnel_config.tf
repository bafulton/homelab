# Tunnel ingress configuration - only allow public domains
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = data.cloudflare_accounts.main.result[0].id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config = {
    ingress = concat(
      # Public subdomains - specific subdomains from any domain
      # Must come before wildcard rules for proper matching
      [for k, v in local.public_subdomains : {
        hostname = "${v.subdomain}.${v.domain}"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }],

      # Root domains for wildcard public domains
      [for k, v in local.wildcard_public_domains : {
        hostname = v.domain
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }],

      # Wildcard subdomains for wildcard public domains
      [for k, v in local.wildcard_public_domains : {
        hostname = "*.${v.domain}"
        service  = "http://traefik.traefik.svc.cluster.local:80"
      }],

      # Catch-all: reject everything else (required by Cloudflare)
      [{
        service = "http_status:404"
      }]
    )
  }
}
