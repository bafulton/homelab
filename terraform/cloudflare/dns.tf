# Wildcard DNS records - all subdomains route to tunnel (domains with wildcard_public=true)
resource "cloudflare_record" "wildcard" {
  for_each = local.wildcard_public_domains

  zone_id = data.cloudflare_zone.zones[each.key].id
  name    = "*"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
}

# Root domain records (optional - for benfulton.me without subdomain)
resource "cloudflare_record" "root" {
  for_each = local.wildcard_public_domains

  zone_id = data.cloudflare_zone.zones[each.key].id
  name    = "@"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
}

# Public subdomain records - specific subdomains from any domain
# e.g., argocd-webhook.catfish-mountain.com for GitHub webhooks
resource "cloudflare_record" "public_subdomains" {
  for_each = local.public_subdomains

  # Look up the zone for this subdomain's parent domain
  zone_id = data.cloudflare_zone.zones[
    [for k, v in local.all_domains : k if v == each.value.domain][0]
  ].id

  name    = each.value.subdomain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
}
