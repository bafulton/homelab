# Redirect every http:// request on a proxied name to https:// at Cloudflare's
# edge. Without it, a typed or linked http:// URL reaches the site unencrypted
# between the browser and Cloudflare, login pages included. It also makes
# apps' "this came in over HTTPS" assumptions true: Home Assistant's public
# route sets X-Forwarded-Proto: https because the tunnel reaches Traefik over
# plain HTTP. DNS-only names (media, games) never pass through this.
resource "cloudflare_zone_setting" "always_use_https" {
  for_each = data.cloudflare_zone.zones

  zone_id    = each.value.id
  setting_id = "always_use_https"
  value      = "on"
}
