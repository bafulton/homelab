# Minted by OpenTofu rather than by hand, so the key is never pasted anywhere.
# Requires an OAuth client with the auth_keys scope AND tag:edge in its tag
# list - the operator's client cannot do this, being scoped to tag:k8s-operator.
# Description is letters and spaces only: the API rejects punctuation with
# "description had invalid characters (400)", and caps the field at 50 chars.
#
# Ephemeral on purpose. Elsewhere in this tailnet ephemeral is a hazard (see
# beelink), but this host holds no state and its recovery is always a rebuild,
# never a repair. Tailscale reaps an offline ephemeral node after roughly 30-60
# minutes, and that matches the recovery: rebuild after the reap and the old
# device is already gone; rebuild sooner and you remove it by hand in the
# console first, or the new VM registers as edge-forwarder-1. A reaped node
# cannot rejoin on its own - cloud-init runs once - which is fine, because the
# healthchecks.io dead man's switch reports it and the fix is a rebuild anyway.
resource "tailscale_tailnet_key" "edge" {
  description   = "OCI edge forwarder managed by opentofu"
  reusable      = true
  ephemeral     = true
  preauthorized = true
  expiry        = var.auth_key_expiry_seconds
  tags          = [var.tailnet_tag]
}
