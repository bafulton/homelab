# Raspberry Pi 5 Talos Setup

The RPi5 node runs **official Talos** via the `siderolabs/sbc-raspberrypi` `rpi_5`
overlay, built through Image Factory. It migrated off the `talos-rpi5` community
images on 2026-10-18.

## Current State

| Component | Value |
|-----------|-------|
| Talos | v1.13.4 |
| Kubernetes | v1.36.2 |
| Schematic | `3ec14befcbf3baad2a84ae0dd95bdfaaed37364451e02b8f3c4b79c52a948d37` |
| Overlay | `rpi_5` |
| Install disk | `/dev/mmcblk0` (SD card) |
| LAN / Tailscale | 192.168.1.84 / 100.115.32.126 |

The schematic is the `rpi_5` overlay plus `configTxtAppend: dtparam=eee=off` and
three extensions:

| Extension | Version | Purpose |
|-----------|---------|---------|
| iscsi-tools | v0.2.0 | Longhorn |
| tailscale | 1.98.3 | tailnet membership |
| util-linux-tools | 2.41.4 | disk tooling |

Pi 5 is community-tested rather than officially tested, so skim
[sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) before bumping
`talosVersion` — support has moved across point releases before (Talos 1.14.0
broke CM5 ethernet, fixed in overlay v0.2.2).

## Config Workflow

rpi5 takes a standard talhelper config. Edit `talconfig.yaml`, then:

```bash
cd talos
./generate-configs.sh
talosctl apply-config --nodes 192.168.1.84 --file clusterconfig/homelab-rpi5.yaml
```

Reach rpi5 by **LAN IP** (`192.168.1.84`) for config operations. Applying config
over the Tailscale hostname can cut the connection mid-apply when the Tailscale
extension restarts.

Use `apply-config` rather than `patch`: `talosctl patch` does not preserve
separate YAML documents and will strip the Tailscale `ExtensionServiceConfig`.

For a single-field change on a running node, pull the live config, edit only
that field, and confirm the diff before applying:

```bash
talosctl get mc v1alpha1 -n 192.168.1.84 -o yaml | yq '.spec' > /tmp/rpi5.yaml
# edit /tmp/rpi5.yaml
talosctl apply-config --nodes 192.168.1.84 --file /tmp/rpi5.yaml --dry-run
talosctl apply-config --nodes 192.168.1.84 --file /tmp/rpi5.yaml --mode=no-reboot
```

Applying the exact running `ExtensionServiceConfig` means Tailscale does not
restart.

## Ethernet: macb TX Stalls

The on-board NIC (`end0`, Cadence macb driver) stalls its TX ring under sustained
upload. Two mitigations are in place:

1. `dtparam=eee=off` baked into the schematic, disabling the BCM54213PE
   AutogrEEEn LPI-wake race ([sbc-raspberrypi#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91))
2. An `EthernetConfig` document in `talconfig.yaml` turning off TSO/GSO and
   enlarging both rings to 4096

Confirm they are live:

```bash
talosctl -n 192.168.1.84 get ethernetstatus end0 -o yaml | grep -A4 rings
# rings: rx 4096 / tx 4096, tx-tcp-segmentation off, tx-generic-segmentation off
```

Stalls still occur under heavy sustained TX and are **recovered automatically**
by the in-kernel watchdog (Talos >= v1.13.3). This log line is expected and
needs no action:

```
macb 1f00100000.ethernet end0: TX stall detected on queue 0 (tail=... head=...); re-kicking TSTART
```

For reference, a 598 GiB restic upload produced two stalls in four hours, both
re-kicked, with no link drop. Investigate only if you see link-down events, or
stalls while the link is otherwise idle:

```bash
talosctl -n 192.168.1.84 dmesg | grep -iE "tx stall|link (up|down)"
```

## Tailscale Extension

Configured as a **separate YAML document**, not under `machine.pods`:

```yaml
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_CLIENT_ID={{ env "TS_CLIENT_ID" }}
  - TS_CLIENT_SECRET={{ env "TS_CLIENT_SECRET" }}?ephemeral=false
  - TS_EXTRA_ARGS=--accept-dns=true --accept-routes --ssh
```

- Use **OAuth client credentials**, not a pre-auth key — OAuth clients don't
  expire and survive reboots
- `?ephemeral=false` keeps the node in the tailnet when it goes offline;
  without it a power loss can get the device reaped
- Credentials live in `talos/.env` (gitignored)

## USB Disk

A 2 TB SanDisk Extreme at `/var/mnt/usb`, holding the Garage object store (the
backup target for Longhorn and VolSync). Declared in `talconfig.yaml`:

```yaml
machine:
  disks:
    - device: /dev/sda
      partitions:
        - mountpoint: /var/mnt/usb
  kubelet:
    extraMounts:
      - destination: /var/mnt/usb
        type: bind
        source: /var/mnt/usb
        options: [bind, rshared, rw]
```

Keep this disk attached. Because the config declares `/dev/sda` as a user disk,
`UserDiskConfigController` retries indefinitely when it is missing, and the
overlay mounts for `/etc/kubernetes`, `/etc/cni`, `/opt` and
`/usr/libexec/kubernetes` never complete — so the kubelet never starts, even
though `EPHEMERAL` provisioned fine. Reattaching the disk clears it immediately
and the existing XFS is mounted, not reformatted.

To adopt a disk that already carries a foreign filesystem, wipe it first:

```bash
talosctl wipe disk sda --nodes 192.168.1.84
talosctl wipe disk sda1 --nodes 192.168.1.84   # if a partition exists
```

## Upgrades

`talosctl upgrade` should now work, since the efivarfs limitation belonged to the
community image. It has not yet been exercised on this node, which is why tuppr
still has `talos.supportsRpi5: false` in `kubernetes/infra/tuppr/values.yaml`.
Run one manual upgrade first, then flip that flag:

```bash
talosctl upgrade --nodes 192.168.1.84 \
  --image factory.talos.dev/installer/3ec14befcbf3baad2a84ae0dd95bdfaaed37364451e02b8f3c4b79c52a948d37:v1.X.X
```

Upgrade `talosctl` itself before upgrading nodes, and drain through
`talos/scripts/safe-reboot-node.sh` rather than rebooting directly — direct
reboots with Longhorn volumes attached risk filesystem corruption.

## Troubleshooting

### Kubelet not starting — CA certificate error

```
error adding CA to root pool: %!w(<nil>)
```

A corrupted cluster CA. Compare the config's `cluster.ca.crt` against the
talhelper-generated config; it should decode with `O=kubernetes` as both subject
and issuer:

```bash
echo "<base64-cert>" | base64 -d | openssl x509 -noout -subject -issuer
```

### Kubelet not starting — no overlay mounts

Check that the USB disk is present; see the USB Disk section above.

### Longhorn pods crashlooping

After an `iscsi-tools` change, clear the backoff:

```bash
kubectl delete pods -n longhorn --field-selector spec.nodeName=rpi5
```

### Port 50000 checks

Use `nc -vz 192.168.1.84 50000` to test the Talos API. The maintenance-mode API
presents a self-signed cert, so `talosctl` needs `--insecure` until the config is
applied.

## Links

- [sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) — the overlay
- [issue #91](https://github.com/siderolabs/sbc-raspberrypi/issues/91) — macb TX stall / EEE
- [issue #82](https://github.com/siderolabs/sbc-raspberrypi/issues/82) — intermittent ethernet dropouts
- [Image Factory](https://factory.talos.dev/)

## Still Unsupported

- PWM/fan control — no driver in the overlay
- NVMe boot — the overlay's U-Boot lacks the BCM2712 PCIe driver; SD card only
