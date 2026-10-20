# Dead man's switch for the public Jellyfin path.
#
# Only this check is managed here. beelink and rpi5 live in the same
# Healthchecks.io project but belong to kubernetes/infra/node-health, which
# creates them on first ping and resets their period and grace on every pod
# start - adopting them here too would give them two owners.
#
# Named after the host, like node-health names its checks (beelink, rpi5).
data "healthchecksio_channel" "email" {
  kind = "email"
}

resource "healthchecksio_check" "edge_forwarder" {
  name    = "edge-forwarder"
  timeout = 120 # matches node-health's 2-minute cadence
  grace   = 300

  channels = [data.healthchecksio_channel.email.id]
}
