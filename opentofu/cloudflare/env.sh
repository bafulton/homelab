# shellcheck shell=bash
#
# Loads the Cloudflare API token for this module from the macOS keychain.
# Source it (don't execute it) before running tofu:
#
#   source ./env.sh && tofu plan
#
# Safe to commit: this file holds no secrets, only a keychain lookup.
#
# The token is "Homelab Terraform" in Cloudflare (DNS, tunnel and zone
# settings edit). It lives only on the workstation: cert-manager has its own
# DNS-only token in BSM. Populate the keychain once, with -w and no value so
# security prompts interactively and the secret never enters shell history:
#
#   security add-generic-password -a "$USER" -s cloudflare-api-token -w

_token=$(security find-generic-password -a "$USER" -s cloudflare-api-token -w 2>/dev/null)

if [ -n "$_token" ]; then
  export CLOUDFLARE_API_TOKEN="$_token"
  echo "cloudflare token loaded from keychain"
else
  echo "env.sh: missing keychain entry 'cloudflare-api-token'. Add it with:" >&2
  echo '  security add-generic-password -a "$USER" -s cloudflare-api-token -w' >&2
fi

unset _token
