# Wildcard DNS records - all subdomains route to tunnel
resource "cloudflare_record" "wildcard" {
  for_each = data.cloudflare_zone.zones

  zone_id = each.value.id
  name    = "*"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
}

# Root domain records (optional - for benfulton.me without subdomain)
resource "cloudflare_record" "root" {
  for_each = data.cloudflare_zone.zones

  zone_id = each.value.id
  name    = "@"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
}
