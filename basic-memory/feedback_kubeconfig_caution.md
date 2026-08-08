---
name: feedback_kubeconfig_caution
description: 'On the work MacBook, be extra cautious before any write to ~/.kube/config — multiple work cluster contexts live there alongside homelab'
metadata:
  node_type: memory
  type: feedback
  originSessionId: a8e70363-dfca-43c1-bfdb-4672b3bba05c
permalink: homelab/feedback-kubeconfig-caution
---

Before touching `~/.kube/config` on the work MacBook (`semgrep-macbook`), explicitly confirm the intent with the user, even for merge-style operations like `talosctl kubeconfig -f` that don't delete other contexts. The user has many Semgrep cluster contexts (prod-*, staging-*, dev-*) in this file and reasonably worries about clobbering work configs from a personal-project session.

**Why:** User flagged this in a 2026-05-11 session when I was about to run `talosctl kubeconfig -f ~/.kube/config` for homelab without first confirming. They were concerned I'd nuke work configs.

**How to apply:**
- For homelab investigations on this machine, prefer non-mutating diagnosis first; ask before any `~/.kube/config` write
- A safer alternative if the user is uneasy: write a side kubeconfig (`~/.kube/homelab.config`) and `export KUBECONFIG=...` for the session
- `kubectl config set-cluster` edits only that cluster entry, but still counts as a write, ask first

Related: [[project-homelab-cluster-access]]
