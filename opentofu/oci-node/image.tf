locals {
  # Keyed on the cluster's Talos version so a reprovision always boots an image
  # matching the fleet. build-oci-image.sh imports talos-<version>-arm64.
  talos_version    = yamldecode(file("${path.module}/../../talos/cluster.yaml")).talosVersion
  talos_image_name = "talos-${local.talos_version}-arm64"
}

# The custom Talos boot image built + imported by build-oci-image.sh.
data "oci_core_images" "talos" {
  compartment_id = var.compartment_ocid
  display_name   = local.talos_image_name
  state          = "AVAILABLE"
}
