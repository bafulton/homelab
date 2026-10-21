# Raspberry Pi 5 Notes

Quirks specific to the rpi5 node. Setup, config generation, upgrades and safe
reboots are all in [README.md](./README.md) — rpi5 uses the standard talhelper
workflow like every other node.

The node runs official Talos through the `siderolabs/sbc-raspberrypi` `rpi_5`
overlay, built via Image Factory. The schematic ID, its `dtparam=eee=off`
append, and the `EthernetConfig` document all live in `talconfig.yaml` with
comments explaining why.

## TX stalls under load are expected

The on-board NIC (`end0`, Cadence macb driver) stalls its TX ring under
sustained upload. This log line is normal and needs no action — the in-kernel
watchdog (Talos >= v1.13.3) recovers it:

```
macb 1f00100000.ethernet end0: TX stall detected on queue 0 (tail=... head=...); re-kicking TSTART
```

For scale: a 598 GiB restic upload produced two stalls in four hours, both
re-kicked, with no link drop. Two mitigations reduce the frequency —
`dtparam=eee=off` in the schematic (disabling the BCM54213PE AutogrEEEn
LPI-wake race, [sbc-raspberrypi#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91))
and the `EthernetConfig` document turning off TSO/GSO with 4096-entry rings.

Investigate only on link-down events, or stalls while the link is idle:

```bash
talosctl -n 192.168.1.84 dmesg | grep -iE "tx stall|link (up|down)"
```

## Keep the USB disk attached

`talconfig.yaml` declares `/dev/sda` as a user disk, so when it is missing
`UserDiskConfigController` retries indefinitely and the overlay mounts for
`/etc/kubernetes`, `/etc/cni`, `/opt` and `/usr/libexec/kubernetes` never
complete. The kubelet then never starts.

This presents misleadingly: `EPHEMERAL` provisions fine and `/var` mounts
read-write, so the storage looks healthy. Reattaching the disk clears it
immediately, and the existing XFS is mounted rather than reformatted.

## Reach rpi5 by LAN IP for config operations

Use `192.168.1.84`, not the Tailscale hostname — applying config over Tailscale
can cut the connection mid-apply when the extension restarts.

## Version bumps need a look upstream

Pi 5 is community-tested, not officially tested. Skim
[sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) before bumping
`talosVersion`: support has broken across point releases before (Talos 1.14.0
broke CM5 ethernet, fixed in overlay v0.2.2), and
[issue #82](https://github.com/siderolabs/sbc-raspberrypi/issues/82)
(intermittent ethernet dropouts) is still open.

`talosctl upgrade` works: rpi5 went v1.13.4 -> v1.14.4 with it (GRUB A/B slots
plus the `rpi_5` overlay installer), rebooting in under 90 seconds with
Tailscale, the USB disk and the end0 ethernet settings intact. Follow
"Upgrade Talos" in `README.md` - rpi5 is a worker, so it needs `--drain=false`.

## Still unsupported

- **PWM/fan control** — no driver in the overlay
- **NVMe boot** — the overlay's U-Boot lacks the BCM2712 PCIe driver; SD card only
