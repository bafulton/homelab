resource "oci_core_vcn" "node" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.name}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "ocifree"
}

resource "oci_core_internet_gateway" "node" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.node.id
  display_name   = "${var.name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "node" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.node.id
  display_name   = "${var.name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.node.id
  }
}

resource "oci_core_security_list" "node" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.node.id
  display_name   = "${var.name}-sl"

  # Unrestricted egress: Tailscale must reach its coordination server (and DERP
  # relays as fallback), the node pulls images and joins the API over Tailscale,
  # and Kilo (if riding Tailscale) also egresses here.
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  # Tailscale's direct-path UDP. Without inbound UDP here the peer connection is
  # likelier to fall back to a DERP relay (slower, shared infra) - and a direct
  # Tailscale path matters if Kilo rides Tailscale (Fix A).
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "17"
    udp_options {
      min = 41641
      max = 41641
    }
  }

  # ICMP path-MTU discovery (frag-needed). Dropping this turns the cross-node
  # MTU mismatch into random mid-stream stalls instead of clean PMTUD - exactly
  # the WireGuard-in-WireGuard hazard we care about here.
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Kilo cross-location WireGuard, only when using the public-endpoint strategy
  # (Fix B). Off by default - Tailscale needs no inbound here. WireGuard auth'd.
  dynamic "ingress_security_rules" {
    for_each = var.kilo_wireguard_ingress ? [1] : []
    content {
      source   = "0.0.0.0/0"
      protocol = "17"
      udp_options {
        min = 51820
        max = 51820
      }
    }
  }
}

# DHCP options WITHOUT a SearchDomain. Because the VCN has a dns_label, OCI's
# default DHCP set hands instances the search domain "<vcn_dns_label>.oraclevcn.com"
# (here ocifree.oraclevcn.com). OCI's internal resolver SERVFAILs (not NXDOMAIN)
# for bogus names under it, so with the pod resolver's ndots:5 every libc
# getaddrinfo tries "<name>.ocifree.oraclevcn.com" first, hits SERVFAIL, and aborts
# the whole lookup - external names fail to resolve in pods on this node. Keeping
# the Internet+VCN resolver but omitting SearchDomain gives a clean resolv.conf
# (cluster.local searches only), so names resolve like any other node. Standard
# remote-node setting; each cloud provider neutralizes its own DNS injection here.
resource "oci_core_dhcp_options" "node" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.node.id
  display_name   = "${var.name}-dhcp"

  options {
    type        = "DomainNameServer"
    server_type = "VcnLocalPlusInternet"
  }
  # Intentionally no `type = "SearchDomain"` option.
}

resource "oci_core_subnet" "node" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.node.id
  display_name               = "${var.name}-subnet"
  cidr_block                 = var.vcn_cidr
  route_table_id             = oci_core_route_table.node.id
  security_list_ids          = [oci_core_security_list.node.id]
  dhcp_options_id            = oci_core_dhcp_options.node.id
  prohibit_public_ip_on_vnic = false
  dns_label                  = "node"
}
