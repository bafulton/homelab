terraform {
  required_version = ">= 1.8.0"

  required_providers {
    oci = { source = "oracle/oci" }
  }
}

# Reads ~/.oci/config [DEFAULT] - user, tenancy, fingerprint, key_file, region.
# Same key as opentofu/oci-forwarder (the tenancy's only API signing key).
provider "oci" {}
