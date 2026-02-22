# iroh-lan-dns

Wrapper around excellent [iroh-lan](https://github.com/rustonbsd/iroh-lan)
which adds a small DNS server similar to MagicDNS in Tailscale,
NixOS module to configure local resolution, and some retry logic.

We can build with Nix

```
nix build
./result/bin/iroh-lan-dns --name network --password secret --hostname node --dns-port 6666
```
or Cargo

```
cargo run -- --name network --password secret --hostname node --dns-port 6666
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

