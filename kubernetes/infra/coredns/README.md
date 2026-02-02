# CoreDNS Deployment Notes

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
