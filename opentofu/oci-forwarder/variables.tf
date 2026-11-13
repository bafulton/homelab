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
  description = "Pin the AD. Leave null to auto-select one whose shape_limit_name quota is above zero."
  type        = string
  default     = null
}

variable "shape_limit_name" {
  description = "OCI limit backing instance_shape, used to find an AD with quota. Must match the shape."
  type        = string
  default     = "standard-e2-micro-core-count"
}

variable "vcn_cidr" {
  description = "VCN range. Arbitrary and private to this VCN - nothing peers with the home network, so it cannot collide with 192.168.1.0/24."
  type        = string
  default     = "10.20.0.0/24"
}

variable "public_hostnames" {
  description = "The only SNIs this forwarder will accept and pass through. Each needs its own hostname-restricted edge listener and certificate in the apps gateway (kubernetes/infra/traefik-apps) and its own A record in opentofu/cloudflare."
  type        = list(string)
  default     = ["media.fultonhuffman.com", "games.fultonhuffman.com"]
}

variable "uptime_probe_hostname" {
  description = "The public hostname whose /health the dead man's switch requests. Jellyfin, because its /health needs no sign-in; games answers every request with a redirect to Pocket ID."
  type        = string
  default     = "media.fultonhuffman.com"
}

variable "games" {
  description = <<-EOT
    Games reachable from the internet, keyed by public name: "minecraft" is
    minecraft.fultonhuffman.com, and with subdomains = true every name under
    it too (*.minecraft.fultonhuffman.com), for a router that picks the
    server by hostname. Each port is forwarded as-is, TCP or UDP, to the
    Tailscale Service game-<key>.catfish-mountain.ts.net, or upstream.
    opentofu/cloudflare reads game_subdomains from this state for the A
    records, and every port also needs the tag:edge grant in
    tailscale/policy.hujson. See README.md, "Game servers".
  EOT
  type = map(object({
    upstream   = optional(string)
    subdomains = optional(bool, false)
    ports = list(object({
      port     = number
      protocol = string
    }))
  }))
  # Minecraft Java sends the hostname it connects to, so one port serves
  # every server: mc-router (kubernetes/apps/mc-router) routes
  # <server>.minecraft.fultonhuffman.com to that server.
  default = {
    minecraft = {
      subdomains = true
      ports      = [{ port = 25565, protocol = "tcp" }]
    }
  }

  validation {
    condition = alltrue(flatten([
      for g in values(var.games) : [for p in g.ports : contains(["tcp", "udp"], p.protocol)]
    ]))
    error_message = "Each game port's protocol must be \"tcp\" or \"udp\"."
  }

  validation {
    condition     = alltrue([for k in keys(var.games) : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", k)) && !contains(["media", "games"], k)])
    error_message = "Game keys become DNS labels under fultonhuffman.com: lowercase letters, digits and hyphens, and not media or games, which are taken."
  }

  validation {
    condition = alltrue(flatten([
      for g in values(var.games) : [
        for p in g.ports : !contains(["tcp:80", "tcp:443", "udp:41641"], "${p.protocol}:${p.port}")
      ]
    ]))
    error_message = "tcp:80, tcp:443 and udp:41641 are the forwarder's own ports."
  }

  validation {
    condition = (
      length(flatten([for g in values(var.games) : [for p in g.ports : "${p.protocol}:${p.port}"]])) ==
      length(distinct(flatten([for g in values(var.games) : [for p in g.ports : "${p.protocol}:${p.port}"]])))
    )
    error_message = "Two games cannot share a public port: the forwarder routes plain TCP and UDP by port alone."
  }
}

variable "exposure_canary_host" {
  description = "A private hostname the health check sends as the Host header behind the public SNI. It must get a 404; anything else fails the check, because private routes would then be reachable from the internet. Longhorn, as the most damaging if exposed (no auth)."
  type        = string
  default     = "longhorn.catfish-mountain.com"
}

variable "upstream" {
  description = "Where passed-through TLS goes: the Traefik gateway published on the tailnet by the Tailscale operator."
  type        = string
  default     = "cluster-apps.catfish-mountain.ts.net:8443"
}

variable "tailnet_tag" {
  description = "Tag this host registers with. The grant in tailscale/policy.hujson limits it to tag:k8s on tcp:8443."
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
