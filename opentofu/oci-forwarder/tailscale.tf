# Minted by OpenTofu rather than by hand, so the key is never pasted anywhere.
# Requires an OAuth client with the auth_keys scope AND tag:edge in its tag
# list - the operator's client cannot do this, being scoped to tag:k8s-operator.
# Description is letters and spaces only: the API rejects punctuation with
# "description had invalid characters (400)", and caps the field at 50 chars.
resource "tailscale_tailnet_key" "edge" {
  description   = "OCI edge forwarder managed by opentofu"
  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = var.auth_key_expiry_seconds
  tags          = [var.tailnet_tag]
}
