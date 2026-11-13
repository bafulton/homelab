# Game echo

A stand-in game server for testing the public path for game traffic: it
echoes back whatever it receives on port 7007, over TCP and over UDP, behind a
Tailscale Service tagged `tag:k8s-games` - the same shape games-manager gives a
real game server. Remove it once games-manager serves real games (CAT-94).

On the tailnet it is `game-echo.catfish-mountain.ts.net:7007`. It is public
only while the forwarder's `games` variable has an `echo` entry, which is
deliberately not committed: an echo server answers anyone.

## Testing the edge

From `opentofu/oci-forwarder`, with a `smoke.tfvars` outside the repo:

```hcl
games = {
  echo = {
    ports = [
      { port = 7007, protocol = "tcp" },
      { port = 7007, protocol = "udp" },
    ]
  }
}
```

```sh
source ./env.sh && tofu apply -var-file=/path/to/smoke.tfvars && ./push-config.sh
cd ../cloudflare && source ./env.sh && tofu apply
```

Then, from a machine off the tailnet (a phone hotspot will do):

```sh
echo hello | nc -w 3 echo.fultonhuffman.com 7007      # TCP: prints hello
echo hello | nc -u -w 3 echo.fultonhuffman.com 7007   # UDP: prints hello
```

A UDP reply is the real check: `nc -u` alone succeeds whether or not anything
answers. If UDP is silent but TCP works, see which hop drops it with
`sudo tcpdump -ni any udp port 7007` on the edge (Tailscale SSH) and in the
`ts-game-echo-*` proxy pod.

Close it again the same way, without the `-var-file`:

```sh
cd ../oci-forwarder && tofu apply && ./push-config.sh
cd ../cloudflare && tofu apply
```
