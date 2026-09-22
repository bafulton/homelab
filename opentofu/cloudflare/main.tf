terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "cloudflare" {
  # Uses CLOUDFLARE_API_TOKEN environment variable
}

data "cloudflare_accounts" "main" {}

# Tunnel
resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id    = data.cloudflare_accounts.main.result[0].id
  name          = "homelab"
  tunnel_secret = random_id.tunnel_secret.b64_std
  config_src    = "cloudflare"


}

resource "random_id" "tunnel_secret" {
  byte_length = 32
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}
