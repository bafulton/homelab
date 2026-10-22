output "instance_id" {
  description = "OCID of the ocifree instance."
  value       = oci_core_instance.node.id
}

output "public_ip" {
  description = "Public IP (Tailscale direct path; Kilo public endpoint if enabled)."
  value       = oci_core_instance.node.public_ip
}

output "private_ip" {
  description = "OCI VCN private IP. Not the Kubernetes node IP - that's the Tailscale address."
  value       = oci_core_instance.node.private_ip
}

output "availability_domain" {
  description = "AD the instance landed in (auto-selected by A1 capacity)."
  value       = local.availability_domain
}

output "tailnet_hostname" {
  description = "How to reach it once Tailscale is up: talosctl -n ocifree.catfish-mountain.ts.net"
  value       = "${var.name}.catfish-mountain.ts.net"
}

output "talos_image" {
  description = "The boot image used (keyed on the talconfig Talos version)."
  value       = local.talos_image_name
}
