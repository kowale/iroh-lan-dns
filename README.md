# Tunnels

We can build with nix

```
nix build
./result/bin/tunnels --name network --password secret --hostname node --dns-port 6666
```

or with cargo

```
cargo run -- --name network --password secret --hostname node --dns-port 6666
```

We will use systemd-resolved for local DNS,
so we must need to forward to port 53

```
sudo iptables -t nat -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j REDIRECT --to-port 6666
```

we also need the resolved config itself, something like this

```nix
{
  services.resolved = {
    enable = true;
    domains = [ "~tunnel.internal" ];
    extraConfig = ''
      DNS=127.0.0.1
      Domains=~tunnel.internal
    '';
  };
}
```

