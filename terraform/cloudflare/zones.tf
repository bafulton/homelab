# Import existing zones (domains must already be added to Cloudflare)
data "cloudflare_zone" "zones" {
  for_each = local.all_domains
  name     = each.value
}
