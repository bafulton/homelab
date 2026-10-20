resource "oci_core_vcn" "fwd" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "edgefwd"
}

resource "oci_core_internet_gateway" "fwd" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.fwd.id
  display_name   = "${var.name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "fwd" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.fwd.id
  display_name   = "${var.name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.fwd.id
  }
}

resource "oci_core_security_list" "fwd" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.fwd.id
  display_name   = "${var.name}-sl"

  # Unrestricted egress. Tailscale must reach its coordination server, and DERP
  # relays if a direct path cannot be established.
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  # 443 - the only reason this host exists.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # 80 - redirect to https so a typed URL still works.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 80
      max = 80
    }
  }

  # Tailscale's direct-path port. Without inbound UDP here the peer connection
  # is likelier to fall back to a DERP relay, which would push video through
  # Tailscale's shared infrastructure - the thing this design exists to avoid.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "17"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  # ICMP path-MTU discovery. Dropping this breaks large packets in ways that
  # look like random stalls mid-stream rather than a connection failure.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Break-glass SSH, shut unless ssh_ingress_cidr is set.
  dynamic "ingress_security_rules" {
    for_each = var.ssh_ingress_cidr == null ? [] : [var.ssh_ingress_cidr]
    content {
      source   = ingress_security_rules.value
      protocol = "6"
      tcp_options {
        min = 22
        max = 22
      }
    }
  }
}

resource "oci_core_subnet" "fwd" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.fwd.id
  display_name               = "${var.name}-subnet"
  cidr_block                 = var.vcn_cidr
  route_table_id             = oci_core_route_table.fwd.id
  security_list_ids          = [oci_core_security_list.fwd.id]
  prohibit_public_ip_on_vnic = false
  dns_label                  = "public"
}
