# The Traefik configs are rendered separately and injected base64-encoded, so
# nested YAML never has to be indented into the cloud-config document.
locals {
  traefik_static = templatefile("${path.module}/templates/traefik.yml.tftpl", {})

  traefik_dynamic = templatefile("${path.module}/templates/dynamic.yml.tftpl", {
    public_hostname = var.public_hostname
    upstream        = var.upstream
  })
}

data "cloudinit_config" "fwd" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"

    content = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      tailscale_authkey    = tailscale_tailnet_key.edge.key
      tailnet_tag          = var.tailnet_tag
      hostname             = var.name
      traefik_version      = var.traefik_version
      traefik_static_b64   = base64encode(local.traefik_static)
      traefik_dynamic_b64  = base64encode(local.traefik_dynamic)
      public_hostname      = var.public_hostname
      exposure_canary_host = var.exposure_canary_host
      healthcheck_ping     = healthchecksio_check.edge_forwarder.ping_url
    })
  }
}
