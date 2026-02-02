# CoreDNS Deployment Notes

## Tailscale Hostname

This CoreDNS instance is exposed via Tailscale as `cluster-dns.catfish-mountain.ts.net`.
Configure this hostname (or its Tailscale IP) in Tailscale Split DNS settings.

## Tailscale Namespace PodSecurity

The `tailscale` namespace requires `pod-security.kubernetes.io/enforce: privileged` to allow Tailscale proxy pods to run.

Tailscale proxies need privileged access for:
- IP forwarding configuration (`sysctl -w net.ipv4.ip_forward=1`)
- Network interface management
- Direct kernel networking capabilities

This was manually applied via:
```bash
kubectl label namespace tailscale pod-security.kubernetes.io/enforce=privileged --overwrite
```

**Security note**: This reduces the security posture of the namespace but is required for Tailscale operator functionality.
