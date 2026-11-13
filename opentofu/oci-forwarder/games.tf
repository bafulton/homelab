# Game servers (var.games): plain TCP and UDP, forwarded by port. Unlike the
# HTTPS passthrough, there is no SNI to check, so the port is the whole
# allowlist - each one opened here reaches exactly one game's Tailscale
# Service and nothing else.
locals {
  game_ports = flatten([
    for name, game in var.games : [
      for p in game.ports : {
        # Traefik entrypoint, router and service name.
        name     = "${name}-${p.protocol}-${p.port}"
        protocol = p.protocol
        port     = p.port
        upstream = "${coalesce(game.upstream, "game-${name}.catfish-mountain.ts.net")}:${p.port}"
      }
    ]
  ])
}
