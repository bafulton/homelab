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
| Theengs Decoder | ✗ Not supported | ✓ Supported | H5106 merged Jan 2023 |
| govee2mqtt | ✗ Not supported | ✗ Not supported | Neither air quality monitor supported |

**Key finding**: No single integration supports both devices.

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

## Recommended Path

**Hybrid approach** (only way to get both devices today):

1. **H5140 (CO₂)**: Use Govee REST API
   - Home Assistant REST sensor polling every 5 minutes
   - API key stored in Kubernetes secret via Bitwarden

2. **H5106 (PM2.5)**: Use ESP32 Bluetooth Proxy
   - ESPHome Bluetooth Proxy on ESP32
   - Home Assistant Govee BLE integration auto-discovers device

### Alternative: Wait for Native Support

- H5140 BLE support requested: https://github.com/orgs/home-assistant/discussions/1410
- No active development as of January 2025

## Contributing H5140 BLE Decoder

To enable a pure BLE approach for both devices, we could contribute an H5140 decoder to Theengs.

### Step 1: Capture Raw BLE Advertisements

Use one of these tools to capture raw advertisement data from the H5140:

- **Theengs Explorer** - TUI app showing raw + decoded data side by side
- **nRF Connect** (iOS/Android) - Scan and view raw manufacturer/service data
- **btmon** on Linux - Low-level Bluetooth HCI monitor

The M5Stack ATOM Lite can also be used with ESPHome's `esp32_ble_tracker` to log raw advertisements.

### Step 2: Known Data Points

From [ble_monitor issue #1509](https://github.com/custom-components/ble_monitor/issues/1509):

- **Device name pattern**: `GV5140xxxx`
- **MAC example**: `DC:1E:D5:CD:0F:FA`
- **Proprietary service UUID**: `494e5445-4c4c-495f-524f-434b535f4857`
- **Hardware version**: 4.01.01
- **Software version**: 1.00.27
- **Sensors**: CO₂ (ppm), temperature, humidity, battery

Need to correlate raw hex values with known readings to reverse-engineer the encoding.

### Step 3: Write Decoder Specification

Theengs decoders are JSON in header files. Create `src/devices/H5140_json.h`:

```cpp
const char* H5140_json = "{\"brand\":\"Govee\",\"model\":\"Smart CO2 Monitor\",\"model_id\":\"H5140\","
    "\"condition\":[\"name\",\"contain\",\"GV5140\"],"
    "\"properties\":{"
        "\"tempc\":{\"decoder\":[\"value_from_hex_data\",\"servicedata\",X,Y,\"false\"],\"post_proc\":[\"/\",100]},"
        "\"hum\":{\"decoder\":[\"value_from_hex_data\",\"servicedata\",X,Y,\"false\"],\"post_proc\":[\"/\",100]},"
        "\"co2\":{\"decoder\":[\"value_from_hex_data\",\"servicedata\",X,Y,\"false\"]},"
        "\"batt\":{\"decoder\":[\"value_from_hex_data\",\"servicedata\",X,Y,\"false\"]}"
    "}}";
```

Replace X, Y with byte offsets determined from captured data.

### Step 4: Validate and Submit

```bash
# Clone the repo
git clone https://github.com/theengs/decoder
cd decoder

# Add your decoder to src/devices/

# Validate JSON format
python scripts/check_decoder.py src/devices/H5140_json.h

# Submit PR
```

### Resources

- Adding decoders guide: https://decoder.theengs.io/participate/adding-decoders.html
- Theengs decoder repo: https://github.com/theengs/decoder
- H5106 decoder PR (reference): https://github.com/theengs/decoder/pull/257

## References

- Govee Developer API: https://developer.govee.com/
- Home Assistant Govee BLE: https://www.home-assistant.io/integrations/govee_ble/
- ESPHome Bluetooth Proxy: https://esphome.io/components/bluetooth_proxy/
- Theengs Decoder: https://github.com/theengs/decoder
- H5106 BLE discussion: https://community.home-assistant.io/t/govee-smart-aqm-monitor-h5106-via-ble/684955
- H5140 BLE data capture: https://github.com/custom-components/ble_monitor/issues/1509
