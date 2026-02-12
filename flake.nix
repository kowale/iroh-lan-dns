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

        tunnels = craneLib.buildPackage rec {
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
          name = "tunnels-smoke-test";

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
              services.tunnels = {
                enable = true;
                package = tunnels;
                networkName = "testnet";
                password = "secret";
                hostname = "node1";
                dnsPort = 6666;
                dns = true;
              };
            };
            node2 = mkNode {
              services.tunnels = {
                enable = true;
                package = tunnels;
                networkName = "testnet";
                password = "secret";
                hostname = "node2";
                dnsPort = 6666;
                dns = true;
              };
            };
          };
          testScript = ''
            start_all()

            node1.wait_for_unit("coredns.service")
            node2.wait_for_unit("coredns.service")

            print(node1.succeed("cat /etc/resolv.conf"))
            print(node2.succeed("cat /etc/resolv.conf"))

            node1.wait_until_succeeds("ping -c 1 8.8.8.8")
            node2.wait_until_succeeds("ping -c 1 8.8.8.8")

            node1.succeed("dig nixos.org")
            node2.succeed("dig nixos.org")

            node1.wait_for_unit("tunnels.service")
            node2.wait_for_unit("tunnels.service")

            node1.wait_for_console_text("Got VPN IP:")
            node2.wait_for_console_text("Got VPN IP:")

            node1_ip = node1.succeed("journalctl -u tunnels.service | grep 'Got VPN IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()
            node2_ip = node2.succeed("journalctl -u tunnels.service | grep 'Got VPN IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()

            node1.wait_until_succeeds(f"ping -c 1 {node2_ip}")
            node2.wait_until_succeeds(f"ping -c 1 {node1_ip}")

            node1.wait_until_succeeds("dig @127.0.0.1 -p 6666 node2.tunnel.internal")
            node2.wait_until_succeeds("dig @127.0.0.1 -p 6666 node1.tunnel.internal")

            node1.succeed("dig @127.0.0.1 node1.tunnel.internal")
            node2.succeed("dig @127.0.0.1 node2.tunnel.internal")

            node1.succeed("dig node1.tunnel.internal")
            node2.succeed("dig node2.tunnel.internal")
          '';
        };

      in
      {
        checks = {
          inherit tunnels;
          integration-test = nixosTest;
        };

        packages = {
          default = tunnels;
          inherit tunnels;
          test = nixosTest.driver;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = tunnels;
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
          cfg = config.services.tunnels;
        in
        {
          options.services.tunnels = {
            enable = lib.mkEnableOption "tunnels = iroh-lan + dns";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.default;
              description = "The tunnels package to use";
            };

            networkName = lib.mkOption {
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

            hostname = lib.mkOption {
              type = lib.types.str;
              default = config.networking.hostName;
              description = "Hostname to announce";
            };

            dnsPort = lib.mkOption {
              type = lib.types.port;
              default = 6666;
              description = "Port for the local DNS server";
            };

            dns = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Local resolution with resolv.conf";
            };
          };

          config = lib.mkIf cfg.enable {
            assertions = [
              {
                assertion = cfg.password != "" || cfg.passwordFile != null;
                message = "services.tunnels requires either password or passwordFile to be set";
              }
            ];

            systemd.services.tunnels = {
              description = "iroh-lan + dns";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                Type = "simple";
                Restart = "on-failure";
                RestartSec = "10s";

                ExecStart = let
                  passwordArg = if cfg.passwordFile != null
                    then "$(cat ${cfg.passwordFile})"
                    else cfg.password;
                in ''
                  ${cfg.package}/bin/tunnels --name ${cfg.networkName} --password ${passwordArg} --hostname ${cfg.hostname} --dns-port ${toString cfg.dnsPort}
                '';

                NoNewPrivileges = false;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
                CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
              };
            };

            networking.nameservers = lib.mkIf cfg.dns [ "127.0.0.1" ];

            services.coredns = lib.mkIf cfg.dns {
              enable = true;
              config = ''
                .:53 {
                  bind 127.0.0.1
                  forward tunnel.internal 127.0.0.1:${toString cfg.dnsPort}
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
