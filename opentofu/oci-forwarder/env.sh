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
# on its own.

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
