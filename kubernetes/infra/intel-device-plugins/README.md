# Intel Device Plugins

Enables Intel GPU hardware acceleration for Kubernetes workloads. Used primarily for QuickSync video transcoding (e.g., Jellyfin).

## Components

| Component | Purpose |
|-----------|---------|
| Node Feature Discovery (NFD) | Auto-labels nodes with hardware capabilities |
| Intel Device Plugins Operator | Manages GPU device plugin deployment |
| GpuDevicePlugin CR | Exposes Intel GPUs as `gpu.intel.com/i915` resources |

## Talos Requirements

1. **System extensions** in Talos image:
   - `siderolabs/i915` - Intel GPU firmware (i915 driver)
   - `siderolabs/intel-ucode` - Intel CPU microcode (recommended)

2. **Generate new Talos image** at https://factory.talos.dev/ with these extensions, then update `talosImageURL` in `talconfig.yaml`

## How It Works

1. **NFD scans hardware** and labels nodes with `intel.feature.node.kubernetes.io/gpu=true` when Intel GPU detected
2. **Operator watches** for `GpuDevicePlugin` CRs
3. **GPU plugin deploys** to labeled nodes and exposes GPUs as schedulable resources
4. **Pods request GPU** via resource limits: `gpu.intel.com/i915: "1"`

## Configuration

Key values in `values.yaml`:

| Value | Default | Description |
|-------|---------|-------------|
| `gpuDevicePlugin.sharedDevNum` | 10 | Pods that can share GPU concurrently |
| `gpuDevicePlugin.resourceManager` | false | Enable fine-grained GPU allocation |
| `gpuDevicePlugin.preferredAllocationPolicy` | none | Allocation policy: `none`, `balanced`, `packed` |

The node selector is hardcoded to `intel.feature.node.kubernetes.io/gpu: "true"` - the label NFD automatically applies to nodes with Intel GPUs.

## Using the GPU in Workloads

Request the GPU in your pod spec:

```yaml
resources:
  limits:
    gpu.intel.com/i915: "1"
```

Example for Jellyfin with hardware transcoding:

```yaml
jellyfin:
  resources:
    limits:
      gpu.intel.com/i915: "1"
```

## Verification

Check that NFD labeled the node:

```bash
kubectl get nodes -L intel.feature.node.kubernetes.io/gpu
```

Check GPU plugin is running:

```bash
kubectl get pods -n intel-device-plugins -l app=intel-gpu-plugin
```

Check GPU resources are available on a node:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.gpu\.intel\.com/i915}{"\n"}{end}'
# Nodes with Intel GPUs should show: 10
```
