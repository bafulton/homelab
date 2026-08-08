---
name: project_homelab_cluster_access
description: 'Accessing the homelab cluster from the work machine — this machine is not the bootstrap host, so a kubeconfig cannot be regenerated here'
metadata:
  node_type: memory
  type: project
  originSessionId: a8e70363-dfca-43c1-bfdb-4672b3bba05c
permalink: homelab/project-homelab-cluster-access
---

The work machine is **not** the bootstrap machine for the homelab cluster. The cluster PKI (the Talos machine config and talosconfig) lives only on whichever machine bootstrapped homelab, so a kubeconfig cannot be regenerated from the work machine.

- The API endpoint per `talos/talconfig.yaml` is `https://beelink.catfish-mountain.ts.net:6443` (Tailscale hostname; the beelink's Tailscale IP changes and should not be hardcoded).
- The work machine has no `~/.talos/config`, no `talos/clusterconfig/` (gitignored), no `talos/.env`, no `talsecret.yaml`. Without talosconfig auth to the Talos API, `talosctl kubeconfig` cannot run here.
- Any `homelab` context already in `~/.kube/config` may be stale (rebuilt cluster or rotated PKI), so verify it works before trusting it.

**Why:** Investigating homelab cluster state from the work machine requires copying `~/.talos/config` and running `talosctl kubeconfig`, or copying a freshly-issued kubeconfig context, from the bootstrap machine. Neither is present here.

**How to apply:**
- Before investigating any "what's happening in homelab" question on the work machine, verify kubectl actually works first: `kubectl --context=homelab --request-timeout=5s get ns`
- If broken, surface this fact early; don't try to fix it from here unless the user provides talosconfig
- Don't auto-edit `~/.kube/config` to "fix" it, see [[feedback-kubeconfig-caution]]
