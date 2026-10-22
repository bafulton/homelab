# Source before tofu: `source ./env.sh`
#
# Exports the OCI compartment OCID (the root compartment = the tenancy) from
# ~/.oci/config so it stays out of git. The oci provider itself reads
# ~/.oci/config [DEFAULT] directly, so no other credentials are needed here -
# unlike the forwarder, ocifree authenticates to Tailscale with the fleet's
# OAuth client baked into its Talos config, so there's no tailscale provider.

_tenancy=$(awk -F= '/^tenancy=/{print $2}' ~/.oci/config 2>/dev/null)
if [ -n "$_tenancy" ]; then
  export TF_VAR_compartment_ocid="$_tenancy"
else
  echo "env.sh: no tenancy= line in ~/.oci/config" >&2
fi
unset _tenancy
