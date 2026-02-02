# Get zones for public domains only
locals {
  public_zones = {
    for key, domain in var.public_domains :
    key => data.cloudflare_zone.zones[key]
  }
}

# Wildcard DNS records - all subdomains route to tunnel (public domains only)
resource "cloudflare_record" "wildcard" {
  for_each = local.public_zones

  zone_id = each.value.id
  name    = "*"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
}

# Root domain records (optional - for benfulton.me without subdomain)
resource "cloudflare_record" "root" {
  for_each = local.public_zones

  zone_id = each.value.id
  name    = "@"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
}
