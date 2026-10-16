---
# STAND-IN DRAFTED BY CLAUDE from your incident notes.
# Rewrite in your own voice or delete before launch.
kind: shave
title: Committed is not applied
date: 2026-09-02
summary: The fix had been in git for months. Neither node had ever heard about it.
descent:
  - Routine node-labelling work, so I had the Tailscale console open
  - Both cluster nodes are registered as ephemeral devices
  - An ephemeral node is reaped from the tailnet as soon as it goes offline
  - talconfig.yaml sets ?ephemeral=false and has done for months
  - That commit was never applied to either running node
  - Regenerating the config is blocked - the Pi's Talos rejects a newer key
resolution: Pull the running config, edit the single field, apply with --mode=no-reboot.
tags:
  - talos
  - tailscale
  - gitops
  - drift
public: false
---

I was doing something else entirely. Renaming node labels, with the Tailscale
admin console open in a tab for an unrelated reason, and I noticed both
cluster nodes carried the **ephemeral** badge.

Ephemeral devices get removed from the tailnet when they go offline. My
control plane reaches those nodes over Tailscale. A long enough power cut —
and I have had power cuts — and the nodes come back up with no identity on the
network I administer them through.

## It was fixed. In git.

`talconfig.yaml` appends `?ephemeral=false` to the auth key. It has since a
commit months old. I had found this, understood it, fixed it, and moved on.

What I had not done was apply it. The commit changed the file that
*generates* machine configuration; it did not change the machine configuration
running on either node. Both had been registered with the old key, at join
time, and nothing since had re-registered them.

This is the part worth writing down. For everything in `kubernetes/`, ArgoCD
closes that gap for me — committed and applied are the same thing within a
couple of minutes, and I have stopped thinking of them as separate states.
Talos is not in that loop. For node configuration, committed and applied are
entirely independent, and nothing was watching the difference.

## And the obvious fix is blocked

The clean move is to regenerate both configs with talhelper and apply them.
That does not work here: the Pi runs an older Talos from a community image,
and the regenerated config contains a key its version does not recognise, so
it rejects the whole document. Its upgrade path is a physical reflash of the
SD card, which is not a thing I will do to fix a query parameter.

So the fix is surgical, and I have been reluctant about this sort of thing
before because a bad `talosctl patch` once stripped the Pi's Tailscale
extension and took the LAN down with it:

```console
$ talosctl -n 192.168.1.84 get mc v1alpha1 -o yaml | yq '.spec' > /tmp/rpi5.yaml
# edit exactly one field
$ talosctl apply-config -n 192.168.1.84 -f /tmp/rpi5.yaml --dry-run
$ talosctl apply-config -n 192.168.1.84 -f /tmp/rpi5.yaml --mode=no-reboot
```

The `get mc` round-trip returns the complete multi-document config, extension
service configuration included. Applying the identical extension block back
means Tailscale never restarts, and `--dry-run` proves the diff is the one
field before anything is written.

The real conclusion is not about Talos either. It is that I have exactly one
system where git is the source of truth, and I had quietly extended that
assumption to a system where it is not.
