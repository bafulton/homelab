data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

# Always Free A1 capacity is granted per availability domain and is not uniform;
# picking the first AD blindly can fail with 400-LimitExceeded. Ask which ADs
# actually have A1 quota and use one of those.
data "oci_limits_resource_availability" "shape" {
  for_each = toset(data.oci_identity_availability_domains.ads.availability_domains[*].name)

  compartment_id      = var.compartment_ocid
  service_name        = "compute"
  limit_name          = var.shape_limit_name
  availability_domain = each.key
}

locals {
  ads_with_capacity = sort([
    for ad, avail in data.oci_limits_resource_availability.shape : ad
    if try(avail.available, 0) >= var.ocpus
  ])

  availability_domain = (
    var.availability_domain != null
    ? var.availability_domain
    : try(local.ads_with_capacity[0], null)
  )

  worker_config = file("${path.module}/${var.worker_config_path}")
}

resource "oci_core_instance" "node" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.talos.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.node.id
    hostname_label   = var.name
    assign_public_ip = true # enables direct Tailscale paths and the optional Kilo public endpoint
  }

  # Talos has no SSH user and no cloud-init; the 'oracle' platform reads the
  # machine config from user_data. The node joins over Tailscale via the
  # beelink API endpoint baked into the config.
  metadata = {
    user_data = base64encode(local.worker_config)
  }

  # Config changes are applied with talosctl, not by replacing the instance, so
  # don't let a later config edit force a destroy/recreate.
  lifecycle {
    ignore_changes = [metadata["user_data"]]

    precondition {
      condition     = length(data.oci_core_images.talos.images) > 0
      error_message = "No AVAILABLE OCI image named '${local.talos_image_name}'. Run opentofu/oci-node/build-oci-image.sh first (it imports the current talconfig Talos version)."
    }

    precondition {
      condition     = local.availability_domain != null
      error_message = "No availability domain has >= ${var.ocpus} OCPUs of ${var.shape_limit_name} quota. Check: oci limits resource-availability get --compartment-id <tenancy> --service-name compute --limit-name ${var.shape_limit_name} --availability-domain <ad>"
    }
  }
}
