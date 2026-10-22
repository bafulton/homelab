variable "compartment_ocid" {
  description = "Compartment for every resource here. env.sh exports it from ~/.oci/config (root compartment = tenancy) so the OCID stays out of git."
  type        = string
}

variable "name" {
  description = "Instance + network resource name, and the instance's tailnet hostname."
  type        = string
  default     = "ocifree"
}

variable "instance_shape" {
  description = "Always Free Ampere A1 (arm64), Flex shape."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ocpus" {
  description = "A1 OCPUs. The Always Free A1 allowance is 2 OCPU / 12 GB total (reduced from 4/24 in 2026); this uses all of it."
  type        = number
  default     = 2
}

variable "memory_gbs" {
  description = "A1 memory in GB. See ocpus - 12 is the full free allowance paired with 2 OCPUs."
  type        = number
  default     = 12
}

variable "shape_limit_name" {
  description = "OCI limit backing the A1 shape, used to find an AD with quota. Must match the shape."
  type        = string
  default     = "standard-a1-core-count"
}

variable "availability_domain" {
  description = "Pin the AD. Leave null to auto-select one whose shape_limit_name quota is above zero."
  type        = string
  default     = null
}

variable "vcn_cidr" {
  description = "ocifree's own VCN range (separate from the forwarder's 10.20.0.0/24). Private to this VCN - nothing peers with the home network, so it cannot collide with 192.168.1.0/24."
  type        = string
  default     = "10.21.0.0/24"
}

variable "boot_volume_gb" {
  description = "Boot volume size (GB). Counts against the 200 GB Always Free block-storage total; the Talos image is small, 50 is plenty."
  type        = number
  default     = 50
}

variable "worker_config_path" {
  description = "Path to ocifree's Talos worker machine config (gitignored; derived from rpi5's live config - see oci-node-plan.md). Delivered as the instance user_data, which the Talos 'oracle' platform reads as its config."
  type        = string
  default     = "../../talos/clusterconfig/homelab-ocifree.yaml"
}

variable "kilo_wireguard_ingress" {
  description = "Open 51820/udp publicly for Kilo's cross-location WireGuard (the chosen 'Fix B': Kilo's own single-hop wg at full MTU, the way Kilo is designed to attach a cloud node - not tunneled inside Tailscale). WireGuard is cryptographically authenticated and silently drops unsolicited packets, so a public wg port is low risk. Pair with the force-endpoint annotation set after join (see README)."
  type        = bool
  default     = true
}
