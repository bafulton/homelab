# Game servers (var.games): plain TCP and UDP, forwarded by port. Unlike the
# HTTPS passthrough, there is no SNI to check, so the port is the whole
# allowlist - each one opened here reaches exactly one game's Tailscale
# Service and nothing else.
locals {
  game_ports = flatten([
    for name, game in var.games : [
      # A range is every port in it, each forwarded on its own: Traefik's
      # entrypoints take one port each.
      for p in game.ports : [
        for port in range(p.port, coalesce(p.to, p.port) + 1) : {
          # Traefik entrypoint, router and service name.
          name     = "${name}-${p.protocol}-${port}"
          protocol = p.protocol
          port     = port
          upstream = "${coalesce(game.upstream, "game-${name}.catfish-mountain.ts.net")}:${port}"
        }
      ]
    ]
  ])
}
