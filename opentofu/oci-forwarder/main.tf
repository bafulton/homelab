terraform {
  required_version = ">= 1.8.0"

  required_providers {
    oci       = { source = "oracle/oci" }
    tailscale = { source = "tailscale/tailscale" }
    cloudinit = { source = "hashicorp/cloudinit" }
    healthchecksio = {
      source  = "kristofferahl/healthchecksio"
      version = "~> 2.3"
    }
  }
}

# Reads ~/.oci/config [DEFAULT] - user, tenancy, fingerprint, key_file, region.
# That key was created 2026-09-23 and is the tenancy's only API signing key.
provider "oci" {}

# Reads TAILSCALE_OAUTH_CLIENT_ID / _SECRET / TAILSCALE_TAILNET.
# Load them from the macOS keychain first: source ./env.sh
provider "tailscale" {}

# Reads HEALTHCHECKSIO_API_KEY (see env.sh). Same project, and the same
# read-write key, as node-health: Healthchecks.io allows one per project.
provider "healthchecksio" {}
