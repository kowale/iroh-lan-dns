{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    crane = {
      url = "github:ipetkov/crane";
    };
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (localSystem:
      let
        # TODO: build for more platforms
        crossSystem = "x86_64-linux";

        pkgs = import nixpkgs {
          inherit localSystem crossSystem;
          overlays = [ (import rust-overlay) ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        iroh-lan-dns = craneLib.buildPackage rec {
          src = craneLib.cleanCargoSource ./.;
          strictDeps = true;
          buildInputs = [ ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];
          cargoArtifacts = craneLib.buildDepsOnly { inherit src strictDeps buildInputs; };
        };

        # NOTE: requires internet access for DHT bootstrap so
        # must run with `nix flake check --option sandbox false`
        nixosTest = pkgs.testers.runNixOSTest {
          name = "iroh-lan-dns-smoke-test";

          nodes = let
            mkNode = cfg: { config, pkgs, lib, ... }: {
              imports = [ self.nixosModules.default cfg ];
              networking.useDHCP = true;
              networking.resolvconf.enable = true;

              # NOTE: if using systemd-networkd, you need systemd-resolved instead
              # services.resolved.enable = true;

              environment.systemPackages = [ pkgs.dig ];
            };

          in {
            node1 = mkNode {
              services.iroh-lan-dns = {
                enable = true;
                package = iroh-lan-dns;
                network = "testnet";
                password = "secret";
                hostName = "node1";
                dnsPort = 6666;
                setupDns = true;
              };
            };
            node2 = mkNode {
              services.iroh-lan-dns = {
                enable = true;
                package = iroh-lan-dns;
                network = "testnet";
                password = "secret";
                hostName = "node2";
                dnsPort = 6666;
                setupDns = true;
              };
            };
          };
          testScript = ''
            start_all()

            node1.wait_for_unit("coredns.service")
            node2.wait_for_unit("coredns.service")

            node1.wait_until_succeeds("ping -c 1 8.8.8.8")
            node2.wait_until_succeeds("ping -c 1 8.8.8.8")

            node1.succeed("dig nixos.org")
            node2.succeed("dig nixos.org")

            node1.wait_for_unit("iroh-lan-dns.service")
            node2.wait_for_unit("iroh-lan-dns.service")

            node1.wait_for_console_text("Got IP:")
            node2.wait_for_console_text("Got IP:")

            node1_ip = node1.succeed("journalctl -u iroh-lan-dns.service | grep 'Got IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()
            node2_ip = node2.succeed("journalctl -u iroh-lan-dns.service | grep 'Got IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()

            node1.wait_until_succeeds(f"ping -c 1 {node2_ip}")
            node2.wait_until_succeeds(f"ping -c 1 {node1_ip}")

            node1.wait_until_succeeds("dig @127.0.0.1 -p 6666 node2.internal")
            node2.wait_until_succeeds("dig @127.0.0.1 -p 6666 node1.internal")

            node1.succeed("dig @127.0.0.1 node1.internal")
            node2.succeed("dig @127.0.0.1 node2.internal")

            node1.succeed("dig node1.internal")
            node2.succeed("dig node2.internal")
          '';
        };

      in
      {
        checks = {
          inherit iroh-lan-dns;
          integration-test = nixosTest;
        };

        packages = {
          default = iroh-lan-dns;
          inherit iroh-lan-dns;
          test = nixosTest.driver;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = iroh-lan-dns;
        };

        devShells.default = craneLib.devShell {
          packages = with pkgs; [
            rustToolchain
            cargo
            rustc
            rust-analyzer
            clippy
            rustfmt
            dig
          ];

          RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
        };
      }
    ) // {
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.iroh-lan-dns;
        in
        {
          options.services.iroh-lan-dns = {
            enable = lib.mkEnableOption "iroh-lan-dns = iroh-lan + dns";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.default;
              description = "The iroh-lan-dns package to use";
            };

            network = lib.mkOption {
              type = lib.types.str;
              example = "mynet";
              description = "Network name for the VPN";
            };

            password = lib.mkOption {
              type = lib.types.str;
              description = "Network password (consider using passwordFile instead)";
              default = null;
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              description = "Path to file containing the network password";
              default = null;
            };

            hostName = lib.mkOption {
              type = lib.types.str;
              default = config.networking.hostName;
              description = "Hostname to announce";
            };

            dnsPort = lib.mkOption {
              type = lib.types.port;
              default = 6666;
              description = "Port for the local DNS server";
            };

            setupDns = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Setup local CoreDNS and add it to nameservers";
            };
          };

          config = lib.mkIf cfg.enable {
            assertions = [
              {
                assertion = cfg.password != "" || cfg.passwordFile != null;
                message = "iroh-lan-dns: you must specify either password or passwordFile to be set";
              }
              {
                assertion = cfg.setupDns -> config.networking.resolvconf.enable || config.services.resolved.enable;
                message = "iroh-lan-dns: you must enable either networking.resolvconf or services.resolved";
              }
            ];

            warnings = lib.optionals (config.services.iroh-lan-dns.password != null)
              [ "this password will be readable in Nix store, consider using passwordFile" ];

            systemd.services.iroh-lan-dns = {
              description = "iroh-lan + dns";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];

              unitConfig = {
                StartLimitIntervalSec = 0;
                StartLimitBurst = 0;
              };

              serviceConfig = {
                Type = "simple";
                Restart = "always";
                RestartSec = "10s";

                ExecStart = let
                  passwordArg = if cfg.passwordFile != null
                    then "$(cat ${cfg.passwordFile})"
                    else cfg.password;
                in ''
                  ${cfg.package}/bin/iroh-lan-dns --network ${cfg.network} --password ${passwordArg} --hostname ${cfg.hostName} --dns-port ${toString cfg.dnsPort}
                '';

                NoNewPrivileges = false;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
                CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
              };
            };

            services.udev.extraRules = ''
              ACTION=="remove", SUBSYSTEM=="net", KERNEL=="tun*", RUN+="${pkgs.systemd}/bin/systemctl restart iroh-lan-dns.service"
            '';

            networking.nameservers = lib.mkIf cfg.setupDns [ "127.0.0.1" ];

            services.coredns = lib.mkIf cfg.setupDns {
              enable = true;
              config = ''
                .:53 {
                  bind 127.0.0.1
                  forward internal 127.0.0.1:${toString cfg.dnsPort}
                  forward . 8.8.8.8 1.1.1.1
                  cache 30
                  log
                  errors
                }
              '';
            };
          };
        };
    };
}
