# MetalLB

Bare-metal load balancer for Kubernetes. Provides LoadBalancer service support without a cloud provider.

## Configuration

This chart creates:

- **IPAddressPool** - Range of IPs MetalLB can assign to LoadBalancer services
- **L2Advertisement** - Announces IPs via ARP on the local network

## Usage

Create a Service with `type: LoadBalancer` and MetalLB will assign an IP from the pool:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  type: LoadBalancer
  ports:
    - port: 80
```
