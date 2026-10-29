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
