# ESP32 BLE Gateway (`ble-gateway`)

A single ESP32 board running [OpenMQTTGateway](https://docs.openmqttgateway.com/) (OMG)
that bridges **Bluetooth Low Energy → MQTT**. It scans BLE advertisements from nearby
sensors, decodes them with the [Theengs](https://decoder.theengs.io/) library, and
publishes the readings to the cluster's Mosquitto broker. Home Assistant consumes them
via MQTT auto-discovery.

This is a **physical device**, not a Kubernetes workload — it can't be managed by ArgoCD.
This directory documents how to re-flash and re-onboard it. The cluster-side pieces:
- `kubernetes/infra/mosquitto/` — the MQTT broker
- `kubernetes/apps/home-assistant/` — HA config + the SigNoz "Smart Home Device Offline" alert

## What it's for

- Decodes BLE sensor broadcasts and republishes them as MQTT so Home Assistant can use them.
- It is the **only** BLE bridge in the house — if it's down, all BLE sensors go stale at
  once, which is what trips the SigNoz **Smart Home Device Offline** alert.

Sensors it currently serves (Govee air-quality monitors):

| Device        | Model | Type            | BLE MAC             | Notes                          |
|---------------|-------|-----------------|---------------------|--------------------------------|
| PM2.5 monitor | H5106 | temp/hum/PM2.5  | `D5:33:C4:06:31:40` |                                |
| CO2 monitor   | H5140 | temp/hum/CO2    | `3C:DC:75:13:A2:D6` | decodes on the development build |

(OMG also supports SwitchBot, Xiaomi/Mijia, etc. — see the Theengs device list.)

## Hardware & firmware

| Property        | Value                                                             |
|-----------------|-------------------------------------------------------------------|
| Board           | **M5Stack ATOM Lite** (small gray cube, no screen, 1 RGB LED)     |
| SoC             | ESP32-PICO-D4 rev v1.1, 40 MHz crystal, 4 MB flash                |
| MAC / device ID | `00:4B:12:A1:39:F8` → OMG device id `004B12A139F8`                |
| Firmware        | **OpenMQTTGateway — `development` build** (reports a git SHA, e.g. `b493dd`) |
| Board build     | **`esp32-m5atom-lite`**                                           |
| OMG modules     | `WebUI`, `IR`, `BT` (BLE)                                         |

The **development** build is the one to use: it carries the latest TheengsDecoder, which
includes the H5140 CO2 decoder. (The H5140 decoder was contributed upstream by us.)

## Network / MQTT configuration

Entered during onboarding (the WiFiManager captive portal). Keep these exact so Home
Assistant entities and the SigNoz alert line up:

| Setting          | Value                                                      |
|------------------|------------------------------------------------------------|
| WiFi SSID        | `LAN of the Free` (2.4 GHz)                                |
| MQTT server      | `192.168.1.202` (Mosquitto's MetalLB LoadBalancer IP)      |
| MQTT port        | `1883` (username/password left blank — LAN-only anonymous) |
| Gateway name     | `ble-gateway`                                              |
| MQTT base topic  | `home/`                                                    |
| Resulting topics | `home/ble-gateway/#` (e.g. `home/ble-gateway/BTtoMQTT/…`)  |
| LAN IP           | `192.168.1.82` (DHCP — confirm via the SYS topic)          |

## How to re-flash and onboard

Re-flashing wipes flash and re-onboards from scratch. It loses no real data — Home
Assistant reconnects the same entities automatically because the device MAC and base
topic are unchanged.

**Have ready:** the device, a **data-capable USB-C cable**, and **Google Chrome or
Microsoft Edge** (the web flasher uses WebSerial).

1. **(Optional) Confirm the chip.** With the device plugged in:
   ```sh
   esptool flash-id            # or: esptool.py flash_id
   ```
   Expect `ESP32-PICO-D4`, 4 MB flash, MAC `00:4b:12:a1:39:f8`.
2. **Open the development web installer** in Chrome/Edge:
   <https://docs.openmqttgateway.com/dev/upload/web-install.html>
   (The firmware channel is set by the URL — the `/dev/` path serves the development build.)
3. In the board dropdown, select **`esp32-m5atom-lite`**.
4. Click **Install**, choose **Erase device**, and let it flash.
5. When it reboots it starts a captive portal. On a phone/laptop, join the WiFi AP named
   **`OMG_ATOM_L`** (open network), then browse to **`http://192.168.4.1`**.
6. Fill in the **Network / MQTT configuration** table above and press **Save**.
7. **Watch the serial console as it reboots.** A good result connects to WiFi, connects to
   the broker, and starts scanning (see `logs/healthy-boot.log`). If the logs don't look
   right, run through the portal configuration again — re-entering and saving the settings
   is the first thing to try, and usually all it takes.
8. Once the logs look healthy, verify with `scripts/gateway-status.sh` (below): you want
   `Connected to broker`, `Scan begin`, and the Govee sensors reporting decoded values
   (H5140 CO2 included).

## Verifying health

Everything observable is on MQTT. From a machine with cluster access:

```sh
./scripts/gateway-status.sh          # SYS status + live BLE traffic via the Mosquitto pod
```

Or manually, exec into the broker and subscribe:

```sh
POD=$(kubectl get pods -n mosquitto -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n mosquitto "$POD" -- \
  mosquitto_sub -h localhost -p 1883 -t 'home/ble-gateway/#' -v
```

Healthy signs:
- `home/ble-gateway/SYStoMQTT` publishes with an increasing `uptime`, `"mqtt":true`, a
  git-SHA `version` (development build), and a reasonable `rssi` (better than ~-80 dBm).
- `home/ble-gateway/BTtoMQTT/#` shows a steady stream of detected BLE devices, and the
  Govee entries carry decoded fields (`tempc`, `hum`, `pm25`, `co2`).
- Scanning runs on an interval (~55 s by default), so allow a scan cycle or two before
  expecting a given sensor to appear.

## Remote control (over MQTT)

OMG accepts commands over MQTT. Publish from the broker pod:

```sh
POD=$(kubectl get pods -n mosquitto -o jsonpath='{.items[0].metadata.name}')
# Restart the gateway
kubectl exec -n mosquitto "$POD" -- \
  mosquitto_pub -h localhost -p 1883 -t 'home/ble-gateway/commands/MQTTtoSYS/config' -m '{"cmd":"restart"}'
# Force an immediate BLE scan
kubectl exec -n mosquitto "$POD" -- \
  mosquitto_pub -h localhost -p 1883 -t 'home/ble-gateway/commands/MQTTtoBT/config' -m '{"interval":0}'
```

## Files

- `README.md` — this document
- `scripts/gateway-status.sh` — one-shot health check (SYS status + live BLE) via MQTT
- `logs/healthy-boot.log` — reference boot log of a healthy `esp32-m5atom-lite` start
