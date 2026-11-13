# mc-router

[mc-router](https://github.com/itzg/mc-router) gives every Minecraft server
one shared public port. A Minecraft Java client sends the hostname it's
connecting to, so mc-router reads it and passes the connection to that
server: `fulton-fun.minecraft.fultonhuffman.com` reaches the `fulton-fun`
server in Gameplane.

```
player ──TCP :25565──> OCI edge forwarder ──Tailscale──> game-minecraft
       (this Service) ──hostname──> fulton-fun's Service ──> game pod
```

- **The edge** forwards TCP 25565, and DNS points `*.minecraft.fultonhuffman.com`
  at it (`opentofu/oci-forwarder`, `var.games`).
- **This Service** is a Tailscale LoadBalancer named `game-minecraft`, tagged
  `tag:k8s-games`, the target of the edge's grant in
  `tailscale/policy.hujson`. Nothing outside the tailnet reaches it directly.
- **Servers** are found by the `mc-router.itzg.me/externalServerName`
  annotation on their Services. mc-router watches Services in every
  namespace, and Gameplane adds the annotation to each Minecraft server
  (`kubernetes/apps/gameplane`, `templates/minecraft-names.yaml`).

## Joining

Players add a server at `<server>.minecraft.fultonhuffman.com`, with no port.
On the LAN, a server's own LoadBalancer address (shown in the dashboard)
works too, and skips the trip through the edge.

The port is open to the whole internet, so every server needs its whitelist
on before its name is shared. mc-router only routes; it doesn't check who's
connecting.

## Troubleshooting

```sh
kubectl -n mc-router logs deploy/mc-router
```

- **The client can't connect, and the logs show no backend for its
  hostname:** the server's Service has no annotation, or a different name. Check it with
  `kubectl -n gameplane-games get svc <server> -o jsonpath='{.metadata.annotations}'`.
  A server created before the naming policy gets its name on its next
  update in the dashboard.
- **mc-router sends players to port 25565 of the server's Service.** That's
  the port every Gameplane Minecraft template uses. A server on another
  port needs its Service port named `mc-router` or `minecraft`, which
  mc-router uses first.
- **Every player appears to come from the edge's tailnet address,** so IP
  bans and per-IP limits in the game see one client. Use whitelists.
