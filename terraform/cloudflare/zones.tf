# Import existing zones (domains must already be added to Cloudflare)
data "cloudflare_zone" "zones" {
  for_each = var.domains
  name     = each.value
}
