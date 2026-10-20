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

locals {
  availability_domain = coalesce(
    var.availability_domain,
    data.oci_identity_availability_domains.ads.availability_domains[0].name,
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
  }
}
