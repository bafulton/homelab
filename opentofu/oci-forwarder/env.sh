# shellcheck shell=bash
#
# Loads the Tailscale provider credentials for this module from the macOS
# keychain. Source it (don't execute it) before running tofu:
#
#   source ./env.sh && tofu plan
#
# Safe to commit: this file holds no secrets, only keychain lookups.
#
# Populate the keychain once, with -w and no value so security prompts
# interactively and the secret never enters shell history:
#
#   security add-generic-password -a "$USER" -s tailscale-oauth-client-id -w
#   security add-generic-password -a "$USER" -s tailscale-oauth-client-secret -w
#
# OCI credentials are not handled here - the oci provider reads ~/.oci/config
# on its own. Two non-secret-but-local values are derived from that config and
# from ~/.ssh so they stay out of git: the compartment (root compartment, i.e.
# the tenancy itself) and the break-glass SSH public key.

_kc() { security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null; }

_id=$(_kc tailscale-oauth-client-id)
_secret=$(_kc tailscale-oauth-client-secret)

if [ -z "$_id" ] || [ -z "$_secret" ]; then
  echo "env.sh: keychain entries missing. Add them with:" >&2
  echo '  security add-generic-password -a "$USER" -s tailscale-oauth-client-id -w' >&2
  echo '  security add-generic-password -a "$USER" -s tailscale-oauth-client-secret -w' >&2
else
  export TAILSCALE_OAUTH_CLIENT_ID="$_id"
  export TAILSCALE_OAUTH_CLIENT_SECRET="$_secret"
  export TAILSCALE_TAILNET=catfish-mountain.ts.net
  echo "tailscale credentials loaded from keychain (tailnet: $TAILSCALE_TAILNET)"
fi

unset _id _secret
unset -f _kc

# Root compartment = the tenancy. Read from ~/.oci/config rather than committed.
_tenancy=$(awk -F= '/^tenancy=/{print $2}' ~/.oci/config 2>/dev/null)
if [ -n "$_tenancy" ]; then
  export TF_VAR_compartment_ocid="$_tenancy"
else
  echo "env.sh: no tenancy= line in ~/.oci/config" >&2
fi

# Break-glass SSH key. Routine access is Tailscale SSH; this is for when that
# is not working.
if [ -r ~/.ssh/id_ed25519.pub ]; then
  export TF_VAR_ssh_authorized_key="$(cat ~/.ssh/id_ed25519.pub)"
else
  echo "env.sh: ~/.ssh/id_ed25519.pub not readable" >&2
fi

unset _tenancy
