# Homebridge

HomeKit bridge that exposes Home Assistant entities to Apple Home. Replaces HA's built-in HomeKit Bridge to gain proper Robot Vacuum Cleaner accessory type support for `vacuum.upstairs_vacuum`.

## Access

| Method | URL | Use Case |
|--------|-----|----------|
| LAN | `http://homebridge.local` | Homebridge UI on home network |
| Private (Tailscale) | `https://homebridge.catfish-mountain.com` | Remote access via Tailscale |

The HomeKit bridge itself (HAP protocol, port 51826) is not a web endpoint — Apple devices discover and connect to it directly via mDNS. Use the Homebridge UI to get the QR code/PIN for pairing.

## Why Homebridge Instead of HA HomeKit Bridge

HA's native HomeKit Bridge only supports fan/light/switch for vacuum entities. Homebridge with the `homebridge-homeassistant` plugin properly maps `vacuum.upstairs_vacuum` to the Robot Vacuum Cleaner HAP accessory category.

## Entities Exposed to Apple Home

| Entity | Type in Apple Home |
|--------|--------------------|
| `alarm_control_panel.*` (all Abode entities) | Security System |
| `light.emilies_lamp` | Light |
| `light.bens_lamp` | Light |
| `sensor.hub_2_tempsensor_temperature` | Temperature Sensor |
| `sensor.hub_2_humisensor_humidity` | Humidity Sensor |
| `sensor.co2` | Air Quality Sensor |
| `sensor.pm2_5` | Air Quality Sensor |
| `binary_sensor.back_door` | Contact Sensor |
| `binary_sensor.front_door` | Contact Sensor |
| `binary_sensor.window` + 9 other window sensors | Contact Sensors |
| `vacuum.upstairs_vacuum` | Robot Vacuum Cleaner |

## Network Configuration

Uses `hostNetwork: true` so Homebridge can broadcast `_hap._tcp` mDNS directly on the LAN. Apple devices discover the bridge automatically without any additional configuration.

HAP port 51826 — different from the old HA bridge (21064), so both can run in parallel during migration.

## Storage

| PVC | Size | Storage Class | Backup |
|-----|------|---------------|--------|
| `homebridge-config` | 2Gi | longhorn-emmc | Daily (5 retained) |

Stores: installed plugins, accessories state cache, and `config.json` (after first-boot seeding).

## Configuration

`config.json` is seeded from `templates/config-template.yaml` on first boot via an init container. The HA long-lived access token is pulled from Bitwarden (ExternalSecret `homebridge-ha-token`) and substituted at boot time. Subsequent pod restarts skip re-seeding.

**Bridge PIN:** `031-45-154` (note this before pairing — used once in Apple Home's "Add Accessory" flow)

**Bridge MAC:** `CE:B5:A7:D9:F2:3C` — do not change after pairing, it identifies this bridge to Apple Home

To update the plugin config after initial setup, modify `templates/config-template.yaml`, then:
```bash
kubectl exec -n homebridge deploy/homebridge -- rm /homebridge/config.json
kubectl rollout restart deploy/homebridge -n homebridge
```

## Initial Setup

1. Complete prerequisites:
   - Create HA long-lived token: **Profile → Security → Long-Lived Access Tokens → Create**
   - Add token to Bitwarden as `homebridge-ha-token` → copy the Bitwarden item UUID
   - Set UUID in `values.yaml` under `bitwarden-secret.secrets[0].data.token`
2. Push to git — ArgoCD syncs automatically
3. Once pod is Running: open `http://homebridge.local` (default credentials: `admin` / `admin`)
4. **Plugins → search "Home Assistant" → install `homebridge-homeassistant`**
   - Verify the platform name shown in the plugin config tab matches `HomebridgeHomeassistant` in `config-template.yaml`; if different, update the configmap and re-seed
5. **Accessories tab** — confirm all entities appear with correct types
6. **iPhone → Home → Add Accessory → scan QR code from Homebridge UI** → enter PIN `031-45-154`
7. Verify parity in Apple Home (all devices present, vacuum shows as Robot Vacuum Cleaner)
8. **Remove HA HomeKit Bridge**: HA → Settings → Integrations → HomeKit Bridge → Delete
9. Remove old bridge from Apple Home: long-press the HASS Bridge tile → Remove Accessory
