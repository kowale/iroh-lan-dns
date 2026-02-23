# iroh-lan-dns

Wrapper around excellent [iroh-lan](https://github.com/rustonbsd/iroh-lan)
that adds an embedded DNS server with hostname announcements
and NixOS module to keep it running and configure local DNS resolution.

## NixOS

```nix
{
  services.iroh-lan-dns = {
    enable = true;
    network = "testnet";
    password = "secret";
    hostName = config.networking.hostName;
    dnsPort = 6666;
    setupDns = true; # leave false if you handle your own DNS
  };
}
```

You can also run a NixOS VM test, but you need to disable sandbox for now;
I am looking into how to self-host iroh discovery so this can run in sandbox.

```
nix flake check -L --option sandbox false
```

You can also run two instances (with different hostnames and ports) to see it in action

```
# in one terminal
nix run . -- --network testnet --password secret --hostname hi --dns-port 6667

# in another terminal
nix run . -- --network testnet --password secret --hostname hello --dns-port 6668
```

## Linux (including NixOS)

```
cargo run -- --network testnet --password secret --hostname hi --dns-port 6666
sudo iptables -t nat -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j REDIRECT --to-port 6666
# TODO: resolv.conf or systemd-resolved
```

## MacOS

```
sudo mkdir -p /etc/resolver/internal
echo "nameserver 127.0.0.1" >> /etc/resolver/internal
sudo cargo run -- --network testnet --password secret --hostname hi --dns-port 53
```

- <https://invisiblethreat.ca/technology/2025/04/12/macos-resolvers/>
- <https://vninja.net/2020/02/06/macos-custom-dns-resolvers/>

## Windows

```powershell
cargo run -- --network testnet --password secret --hostname hi --dns-port 53
Add-DnsClientNrptRule -Namespace "internal" -NameServers "127.0.0.1"
Get-DnsClientNrptRule | Where-Object {$_.Namespace -eq "internal"}
```

