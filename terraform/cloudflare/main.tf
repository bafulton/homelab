terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
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
  account_id = data.cloudflare_accounts.main.accounts[0].id
  name       = "homelab"
  secret     = random_id.tunnel_secret.b64_std
}

resource "random_id" "tunnel_secret" {
  byte_length = 32
}

# Output tunnel token for Kubernetes deployment
output "tunnel_token" {
  value     = cloudflare_zero_trust_tunnel_cloudflared.homelab.tunnel_token
  sensitive = true
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}
