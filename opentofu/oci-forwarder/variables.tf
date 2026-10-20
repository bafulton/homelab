variable "compartment_ocid" {
  description = "Compartment for every resource here. env.sh exports this from ~/.oci/config so the OCID stays out of git."
  type        = string
}

variable "name" {
  description = "Name for the instance and its network resources, and the instance's tailnet hostname."
  type        = string
  default     = "edge-forwarder"
}

variable "instance_shape" {
  description = "Always Free AMD micro. Confirmed offered in us-ashburn-1."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "boot_volume_gb" {
  description = "Boot volume size. Counts against the 200 GB Always Free block-storage total; 50 is the image default."
  type        = number
  default     = 50
}

variable "availability_domain" {
  description = "Override the AD. Leave null to use the first. E2.1.Micro capacity is per-AD, so a capacity error means trying another."
  type        = string
  default     = null
}

variable "vcn_cidr" {
  description = "VCN range. Arbitrary and private to this VCN - nothing peers with the home network, so it cannot collide with 192.168.1.0/24."
  type        = string
  default     = "10.20.0.0/24"
}

variable "public_hostname" {
  description = "The only SNI this forwarder will accept and pass through."
  type        = string
  default     = "media.fultonhuffman.com"
}

variable "upstream" {
  description = "Where passed-through TLS goes: the Traefik gateway published on the tailnet by the Tailscale operator."
  type        = string
  default     = "cluster-gateway.catfish-mountain.ts.net:443"
}

variable "tailnet_tag" {
  description = "Tag this host registers with. The grant in tailscale/policy.hujson limits it to tag:k8s on tcp:443."
  type        = string
  default     = "tag:edge"
}

variable "auth_key_expiry_seconds" {
  description = "Lifetime of the generated auth key. Only needs to outlive first boot; a rebuild mints a new one."
  type        = number
  default     = 7776000 # 90 days
}

variable "traefik_version" {
  description = "Traefik release to install on the edge, without the leading v."
  type        = string
  default     = "3.3.4"
}

variable "ssh_authorized_key" {
  description = "Public key placed on the instance. Break-glass only - routine access is Tailscale SSH."
  type        = string
}

variable "ssh_ingress_cidr" {
  description = "Set temporarily to open :22 publicly if Tailscale cannot be reached. Null keeps it shut; the real break-glass is the OCI serial console."
  type        = string
  default     = null
}
