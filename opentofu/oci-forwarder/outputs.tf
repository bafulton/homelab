output "public_ip" {
  description = "Ephemeral public IP. opentofu/cloudflare reads this from state for the media and games A records."
  value       = oci_core_instance.fwd.public_ip
}

output "availability_domain" {
  description = "Which AD the instance landed in, for when capacity forces a change."
  value       = local.availability_domain
}

output "image_name" {
  description = "Ubuntu image actually selected, so a surprise rebuild is traceable."
  value       = data.oci_core_images.ubuntu.images[0].display_name
}

output "game_subdomains" {
  description = "Public game names under fultonhuffman.com: var.games keys, and *.<key> for games with subdomains. opentofu/cloudflare reads this for their DNS-only A records."
  value = sort(concat(
    keys(var.games),
    [for name, game in var.games : "*.${name}" if game.subdomains],
  ))
}

# What push-config.sh writes to the running VM. cloud-init only runs on first
# boot, so these are how a change to var.games reaches the edge without a
# rebuild (and a new public IP). Neither holds a secret.
output "traefik_static" {
  description = "Rendered /etc/traefik/traefik.yml."
  value       = local.traefik_static
}

output "traefik_dynamic" {
  description = "Rendered /etc/traefik/dynamic.yml."
  value       = local.traefik_dynamic
}

output "game_firewall_rules" {
  description = "Host iptables ACCEPT rules for the game ports, as \"<protocol> <port>\"."
  value       = [for p in local.game_ports : "${p.protocol} ${p.port}"]
}
