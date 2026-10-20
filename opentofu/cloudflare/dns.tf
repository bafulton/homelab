# Wildcard DNS records - all subdomains route to tunnel (domains with wildcard_public=true)
resource "cloudflare_dns_record" "wildcard" {
  for_each = local.wildcard_public_domains

  zone_id = data.cloudflare_zone.zones[each.key].id
  name    = "*"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Root domain records (optional - for benfulton.me without subdomain)
resource "cloudflare_dns_record" "root" {
  for_each = local.wildcard_public_domains

  zone_id = data.cloudflare_zone.zones[each.key].id
  name    = "@"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Public subdomain records - specific subdomains from any domain
# e.g., argocd-webhook.catfish-mountain.com for GitHub webhooks
resource "cloudflare_dns_record" "public_subdomains" {
  for_each = local.public_subdomains

  # Look up the zone for this subdomain's parent domain
  zone_id = data.cloudflare_zone.zones[
    [for k, v in local.all_domains : k if v == each.value.domain][0]
  ].id

  name    = each.value.subdomain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# Jellyfin bypasses the tunnel entirely: serving video through Cloudflare's CDN
# is outside their Service-Specific Terms, and all four domains ride one tunnel,
# so an enforcement action against it would take the rest of them down too.
#
# A specific record beats the "*" CNAME above, so the wildcard and the tunnel
# ingress rule both stay exactly as they are - which is also the rollback:
# remove this resource and traffic returns to the tunnel on its own. Flipping
# proxied to true is NOT a rollback; that would point the CDN at the forwarder.
#
# proxied = false is the load-bearing field. The IP is read from the forwarder
# module's state rather than retyped, so the two configs cannot drift.
resource "cloudflare_dns_record" "media_direct" {
  zone_id = data.cloudflare_zone.zones["fultonhuffman-com"].id
  name    = "media"
  type    = "A"
  content = data.terraform_remote_state.oci_forwarder.outputs.public_ip
  proxied = false
  ttl     = 300 # low and explicit, so a rollback propagates fast
}

data "terraform_remote_state" "oci_forwarder" {
  backend = "local"

  config = {
    path = "../oci-forwarder/terraform.tfstate"
  }
}
