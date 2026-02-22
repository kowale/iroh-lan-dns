# iroh-lan-dns

Wrapper around excellent [iroh-lan](https://github.com/rustonbsd/iroh-lan)
which adds a small DNS server similar to MagicDNS in Tailscale,
NixOS module to configure local resolution, and some retry logic.

You can use Nix

```
nix run . -- --name network --password secret --hostname node --dns-port 6666
```
or Cargo

```
cargo run -- --name network --password secret --hostname node --dns-port 6666
```

or NixOS module (preferred)

```nix
{
  services.iroh-lan-dns = {
    enable = true;
    package = iroh-lan-dns;
    networkName = "testnet";
    password = "secret";
    hostname = "node1";
    dnsPort = 6666;
    dns = true; # this is quite invasive, disable if you handle your own DNS
  };
}
```

You can also run a NixOS VM test, but you need to disable sandbox for now;
I am looking into how to self-host iroh discovery so this can run in sandbox.

```
nix flake check -L --option sandbox false
```

## Local DNS resolution

Skip this step if using the NixOS module.
We can use systemd-resolved for local DNS,
so we must need to forward to port 53

```
sudo iptables -t nat -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j REDIRECT --to-port 6666
```

we also need the resolved config itself, something like this

```nix
{
  services.resolved = {
    enable = true;
    domains = [ "~internal" ];
    extraConfig = ''
      DNS=127.0.0.1
      Domains=~internal
    '';
  };
}
```

