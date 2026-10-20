data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Always Free micro quota is granted per availability domain and is not
# uniform: in us-ashburn-1 it was 0 in AD-1 and AD-2 and 2 in AD-3. Picking the
# first AD blindly fails with 400-LimitExceeded, so ask which ADs actually have
# capacity and use one of those.
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
    if try(avail.available, 0) > 0
  ])

  availability_domain = (
    var.availability_domain != null
    ? var.availability_domain
    : try(local.ads_with_capacity[0], null)
  )
}

resource "oci_core_instance" "fwd" {
  availability_domain = local.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.name
  shape               = var.instance_shape

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.fwd.id
    hostname_label   = replace(var.name, "-", "")
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = var.ssh_authorized_key
    user_data           = data.cloudinit_config.fwd.rendered
  }

  # A new auth key alone should not replace the host; cloud-init only consumes
  # it on first boot, and tailscaled keeps its own state afterwards.
  lifecycle {
    ignore_changes = [metadata["user_data"]]

    precondition {
      condition     = local.availability_domain != null
      error_message = "No availability domain has ${var.shape_limit_name} quota. Check with: oci limits resource-availability get --compartment-id <tenancy> --service-name compute --limit-name ${var.shape_limit_name} --availability-domain <ad>"
    }
  }
}
