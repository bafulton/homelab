# Govee Air Quality Monitor Integration Research

Research notes on integrating Govee H5140 (CO₂) and H5106 (PM2.5) monitors into Home Assistant on Talos Linux.

## Devices

| Device | Model | Sensors | Connectivity |
|--------|-------|---------|--------------|
| Smart CO₂ Monitor | H5140 | CO₂, temperature, humidity | WiFi + BLE |
| Smart Air Quality Monitor | H5106 | PM2.5, temperature, humidity | WiFi + BLE |

## Integration Support Matrix

| Integration | H5140 (CO₂) | H5106 (PM2.5) | Notes |
|-------------|-------------|---------------|-------|
| Govee REST API | ✓ Works | ✗ Not supported | H5106 has `isAPIDevice: false` |
| Govee BLE (Home Assistant) | ✗ Not supported | ✓ Supported | H5140 not in supported devices list |
| Theengs Decoder | ⏳ PR submitted | ✓ Supported | H5140 PR: [#684](https://github.com/theengs/decoder/pull/684) |
| govee2mqtt | ✗ Not supported | ✗ Not supported | Neither air quality monitor supported |

**Status**: H5140 decoder PR submitted to Theengs. Once merged, both devices will work via OpenMQTTGateway.

## Govee REST API

- **Documentation**: https://developer.govee.com/docs/support-product-model
- **API Endpoint**: `https://openapi.api.govee.com/router/api/v1/`
- **Rate Limit**: 10,000 requests/day

### Supported H51xx Models (Official)

```
H5100, H5103, H5127, H5160, H5161, H5179
```

Neither H5140 nor H5106 is in the official list, but H5140 works anyway.

### H5140 API Response

Successfully queried device ID `52:5C:3C:DC:75:13:A2:D4`:

```json
{
  "payload": {
    "sku": "H5140",
    "device": "52:5C:3C:DC:75:13:A2:D4",
    "capabilities": [
      {"instance": "co2", "state": {"value": 658}},
      {"instance": "sensorTemperature", "state": {"value": 2234}},
      {"instance": "sensorHumidity", "state": {"value": 4500}}
    ]
  }
}
```

- Temperature: value / 100 = degrees (unit depends on device setting)
- Humidity: value / 100 = percent
- CO₂: value in ppm

### H5106 API Response

Device MAC `98:17:3C:0D:6C:54` returns error:

```json
{"code": 400, "msg": "devices not exist"}
```

The H5106's WiFi is for cloud sync to the Govee mobile app only, not API access.

## Bluetooth on Talos Linux

### Hardware Detection

The cluster node has an Intel AX101 WiFi/Bluetooth combo module:

```
$ talosctl read /sys/class/bluetooth
error reading file: file does not exist
```

Bluetooth subsystem not initialized - no `/sys/class/bluetooth` directory.

### Firmware Status

The Intel AX101 requires firmware files that are not included in Talos by default:

- `intel/ibt-0190-0291-hw1.sfi`
- Required kernel module: `btusb`

As of January 2025:
- Firmware exists in upstream linux-firmware repository
- No Talos system extension packages the Bluetooth firmware
- The `intel-bluetooth-firmware` extension would need to be created or contributed

### Relevant Issues

- Talos firmware extensions: https://github.com/siderolabs/extensions
- Intel AX101 discussion: https://github.com/siderolabs/talos/issues/6292

## BLE Integration Options

### Option 1: ESP32 Bluetooth Proxy

An ESP32 running ESPHome acts as a Bluetooth proxy, forwarding BLE advertisements to Home Assistant over WiFi.

**Pros**:
- Inexpensive (~$5-10)
- No changes needed to Talos
- Can be placed near devices for better range
- Works with Home Assistant's Govee BLE integration

**Cons**:
- Additional hardware
- Only helps H5106 (H5140 not supported in Govee BLE)

**Hardware**: M5Stack ATOM Lite (ESP32-PICO-D4, 24x24mm, USB-C, ~$7)

**ESPHome config**:
```yaml
esp32:
  board: m5stack-atom
  framework:
    type: arduino

bluetooth_proxy:
  active: true
```

**Resources**:
- https://esphome.io/components/bluetooth_proxy/

### Option 2: Theengs Gateway on ESP32

ESP32 running Theengs Gateway decodes BLE advertisements and publishes to MQTT.

**Pros**:
- Theengs has H5106 decoder (merged Jan 2023)
- Decodes data on the ESP32, publishes clean MQTT messages

**Cons**:
- H5140 not supported in Theengs decoder
- Requires MQTT broker

**Resources**:
- https://github.com/theengs/decoder
- H5106 support: https://github.com/theengs/decoder/issues/257

### Option 3: USB Bluetooth Adapter

Add a USB Bluetooth dongle to the Talos node.

**Cons**:
- Talos may not have drivers for common BT adapters
- Would need to verify kernel module support
- Still only helps H5106

### Option 4: Dedicated BLE Gateway

Raspberry Pi or similar running Home Assistant or Theengs Gateway.

**Pros**:
- Full Linux with all drivers
- Can run multiple integrations

**Cons**:
- Additional hardware and power
- Another system to maintain

## Planned Path Forward

**Theengs Gateway** - unified BLE approach for both devices via MQTT.

### Why This Approach

- Both devices on same integration path (no hybrid REST + BLE)
- Theengs already supports H5106; we'll contribute H5140 decoder
- Decoding happens on ESP32, Home Assistant receives clean data via MQTT
- Avoids reported data quality issues with Home Assistant's Govee BLE integration

### Architecture

```
┌─────────────┐      BLE       ┌─────────────┐      MQTT       ┌─────────────┐
│   Govee     │ ─────────────► │   ESP32     │ ──────────────► │  Mosquitto  │
│   H5140     │  advertisements│   Theengs   │  decoded values │   Broker    │
│   H5106     │                │   Gateway   │                 │  (cluster)  │
└─────────────┘                └─────────────┘                 └──────┬──────┘
                                                                      │
                                                                      ▼
                                                               ┌─────────────┐
                                                               │    Home     │
                                                               │  Assistant  │
                                                               │   (MQTT     │
                                                               │ integration)│
                                                               └─────────────┘
```

### Implementation Steps

1. **Add Mosquitto MQTT broker to cluster**
   - New app in `kubernetes/infra/mosquitto/`
   - Lightweight (~10MB RAM), minimal config
   - Expose via ClusterIP for internal access

2. **Get M5Stack ATOM Lite**
   - ESP32-PICO-D4, USB-C, 24x24mm, ~$7
   - https://shop.m5stack.com/products/atom-lite-esp32-development-kit

3. **Flash with Theengs Gateway**
   - https://gateway.theengs.io/
   - Configure MQTT broker connection (point to Mosquitto service)

4. **H5106 works immediately**
   - Theengs decoder merged Jan 2023
   - PM2.5, temperature, humidity available via MQTT

5. **Capture H5140 BLE data**
   - Use Theengs Explorer or nRF Connect to capture raw advertisements
   - Correlate hex values with known readings

6. **Contribute H5140 decoder to Theengs**
   - See "Contributing H5140 BLE Decoder" section below
   - Submit PR to https://github.com/theengs/decoder

7. **Configure Home Assistant MQTT integration**
   - Auto-discovers sensors published by Theengs Gateway
   - Both devices appear as sensors in Home Assistant

### Prerequisites

- [x] Mosquitto MQTT broker deployed (`192.168.0.202:1883`, `mosquitto.local`)
- [x] M5Stack ATOM Lite acquired
- [x] OpenMQTTGateway flashed and configured (`ble-gateway` at `192.168.0.29`)
- [x] H5106 (PM2.5) working in Home Assistant
- [x] H5140 decoder PR submitted: [theengs/decoder#684](https://github.com/theengs/decoder/pull/684)
- [ ] H5140 decoder merged and OpenMQTTGateway updated

## H5140 BLE Decoder (Completed)

PR submitted: [theengs/decoder#684](https://github.com/theengs/decoder/pull/684)

### BLE Manufacturer Data Format

The H5140 broadcasts 10 bytes (20 hex characters) of manufacturer data:

| Hex Position | Bytes | Description |
|--------------|-------|-------------|
| 0-7 | 0-3 | Header (`01000101`) |
| 8-13 | 4-6 | 24-bit combined temp/humidity |
| 14-17 | 7-8 | 16-bit CO2 in ppm (big-endian) |
| 18-19 | 9 | Padding/unknown |

### Decoding Formulas

- **Temperature (°C)**: `24bit_value / 10000`
- **Humidity (%)**: `(24bit_value % 1000) / 10`
- **CO2 (ppm)**: `16bit_value` (direct reading)

### Example

Raw data: `0100010103fcbf044c00`
- Header: `01000101`
- Temp/Hum: `03fcbf` = 261311 decimal
  - Temperature: 261311 / 10000 = **26.13°C**
  - Humidity: (261311 % 1000) / 10 = **31.1%**
- CO2: `044c` = **1100 ppm**

### Live Samples

| Manufacturer Data | Display Reading | Decoded Values |
|-------------------|-----------------|----------------|
| `0100010103fcbf044c00` | 78.4°F, 31%, 1100 ppm | temp=26.13°C, hum=31.1%, co2=1100 |
| `0100010103fc56045600` | 78.8°F, 31%, 1110 ppm | temp=26.13°C, hum=31.0%, co2=1110 |
| `0100010103fc4e045400` | 78.8°F, 31%, 1108 ppm | temp=26.13°C, hum=31.0%, co2=1108 |

### Decoder JSON

```json
{
   "brand":"Govee",
   "model":"Smart CO2 Monitor",
   "model_id":"H5140",
   "tag":"0301",
   "condition":["name", "contain", "GV5140", "&", "manufacturerdata", ">=", 20, "index", 0, "01000101"],
   "properties":{
      "tempc":{
         "decoder":["value_from_hex_data", "manufacturerdata", 8, 6, false, false],
         "post_proc":["/", 10000]
      },
      "hum":{
         "decoder":["value_from_hex_data", "manufacturerdata", 8, 6, false, false],
         "post_proc":["&", 2147483647, "%", 1000, "/", 10]
      },
      "co2":{
         "decoder":["value_from_hex_data", "manufacturerdata", 14, 4, false, false]
      }
   }
}
```

### Related Issues

- Home Assistant Feature Request: https://github.com/orgs/home-assistant/discussions/1410
- BLE Monitor Issue: https://github.com/custom-components/ble_monitor/issues/1509

## References

- Govee Developer API: https://developer.govee.com/
- Home Assistant Govee BLE: https://www.home-assistant.io/integrations/govee_ble/
- ESPHome Bluetooth Proxy: https://esphome.io/components/bluetooth_proxy/
- Theengs Decoder: https://github.com/theengs/decoder
- H5106 BLE discussion: https://community.home-assistant.io/t/govee-smart-aqm-monitor-h5106-via-ble/684955
- H5140 BLE data capture: https://github.com/custom-components/ble_monitor/issues/1509
- **H5140 Decoder PR**: https://github.com/theengs/decoder/pull/684
