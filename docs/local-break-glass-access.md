# Local administrative break-glass access

Use an authorized workstation on the home LAN when Tailscale or public login
is unavailable. Existing Talos and Kubernetes client certificates authenticate
directly to the nodes; Pocket ID, browser login, DNS, and the ingress gateways
are not involved. This verifies API access, not cluster survival during a WAN
outage or recovery from a failed control plane.

## Prerequisites

- `talosctl` compatible with the running Talos version, and `kubectl` compatible
  with the Kubernetes API.
- Existing Talos administrator credentials in `~/.talos/config` (or the file
  selected by `TALOSCONFIG` / `--talosconfig`). The generated source is
  `talos/clusterconfig/talosconfig`.
- Existing certificate-based Kubernetes administrator credentials and cluster
  CA in `~/.kube/config` (or `KUBECONFIG` / `--kubeconfig`), with the homelab
  context selected. An OIDC-only kubeconfig is not sufficient for this path.
- LAN connectivity to beelink, `192.168.1.86`, on TCP 50000 (Talos) and 6443
  (Kubernetes). The Pi's Talos API is also at `192.168.1.84:50000`.

Keep credential files private and securely backed up outside Git. Client
certificates expire: check Talos validity with `talosctl config info`, and
inspect the Kubernetes client's public certificate expiry before relying on
stored credentials. Renew Talos credentials while valid using
`talosctl config new <new-private-file>`; retrieve fresh Kubernetes credentials
using a valid Talos administrator configuration as shown below. If Talos
credentials have already expired, recovery requires the securely held cluster
secrets (`talos/secrets.yaml`) to regenerate credentials; this is not a login
fallback. Do not regenerate cluster secrets or commit credential material.

## Connect directly over the LAN

These overrides affect only the command being run; they do not change the
normal Tailscale endpoints in your configuration.

```sh
talosctl -e 192.168.1.86 -n 192.168.1.86 version

kubectl \
  --server=https://192.168.1.86:6443 \
  --tls-server-name=beelink.catfish-mountain.ts.net \
  get nodes
```

The Kubernetes TLS server-name override validates the existing certificate
against its DNS identity while connecting to the LAN IP; it does not resolve
that hostname. Keep CA validation enabled. Talos uses its existing cluster CA
and client credentials; do not use `--insecure` or Kubernetes
`--insecure-skip-tls-verify`.

To inspect the Pi directly, use:

```sh
talosctl -e 192.168.1.84 -n 192.168.1.84 version
```

The Pi is a worker, not a replacement Kubernetes API endpoint. If the existing
kubeconfig is missing or expired but Talos access to beelink works, download a
fresh one to a new private file, without replacing the normal configuration:

```sh
umask 077
talosctl -e 192.168.1.86 -n 192.168.1.86 \
  kubeconfig --merge=false "$HOME/.kube/homelab-break-glass"

kubectl --kubeconfig="$HOME/.kube/homelab-break-glass" \
  --server=https://192.168.1.86:6443 \
  --tls-server-name=beelink.catfish-mountain.ts.net \
  get nodes
```

For a timeout, check LAN connectivity, node power, and the current LAN address.
For a certificate/authentication failure, check the selected context, client
certificate expiry, cluster CA, and workstation clock. Failure of the
Kubernetes API with working Talos access may require node/service diagnosis;
see [Talos maintenance and recovery](../talos/README.md#maintenance-commands).

## Access boundary and verification

Credential-protected LAN Talos/Kubernetes APIs are intentional exceptions to
CAT-17's Tailscale-only administrative **web** interfaces. They do not expose
Argo CD or other administrative dashboards on the LAN, and require no router
port forwarding. This procedure does not change firewall or access policies.

For CAT-20, the owner ran the first two commands on the home LAN and explicitly
confirmed Tailscale was disabled. Talos returned authenticated server version
`v1.14.5` with RBAC enabled; Kubernetes returned beelink, ocifree, and rpi5 all
`Ready`, running `v1.37.2`. Neither check required public OIDC. The Pi endpoint
and credential-refresh instructions are available recovery options, not part
of that owner-confirmed test.
