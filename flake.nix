{
  description = "Tunnels - P2P VPN with DNS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        commonArgs = {
          src = craneLib.cleanCargoSource ./.;
          strictDeps = true;
          buildInputs = [ ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        tunnels = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
        });

        # NOTE: requires internet access for DHT bootstrap,
        # must run with `nix flake check --option sandbox false`
        nixosTest = pkgs.testers.runNixOSTest {
          name = "tunnels-smoke-test";

          nodes = {
            node1 = { config, pkgs, ... }: {
              imports = [ self.nixosModules.default ];

              services.tunnels = {
                enable = true;
                package = tunnels;
                networkName = "testnet";
                password = "testsecret";
                hostname = "node1";
                dnsPort = 6666;
              };

              # Enable internet access in test VM
              networking = {
                useDHCP = true;
                firewall.enable = false;
              };

              # Needed for testing
              environment.systemPackages = [ pkgs.dig pkgs.iputils pkgs.netcat pkgs.curl ];
            };

            node2 = { config, pkgs, ... }: {
              imports = [ self.nixosModules.default ];

              services.tunnels = {
                enable = true;
                package = tunnels;
                networkName = "testnet";
                password = "testsecret";
                hostname = "node2";
                dnsPort = 6666;
              };

              # Enable internet access in test VM
              networking = {
                useDHCP = true;
                firewall.enable = false;
              };

              environment.systemPackages = [ pkgs.dig pkgs.iputils pkgs.netcat pkgs.curl ];
            };
          };

          testScript = ''
            start_all()

            node1.wait_for_unit("network-online.target")
            node2.wait_for_unit("network-online.target")

            node1.succeed("dig +short google.com")
            node1.succeed("ping -c 2 8.8.8.8")
            node1.succeed("curl -I https://google.com")

            node1.wait_for_unit("tunnels.service")
            node2.wait_for_unit("tunnels.service")

            node1.wait_for_console_text("Got VPN IP:")
            node2.wait_for_console_text("Got VPN IP:")

            node1_ip = node1.succeed("journalctl -u tunnels.service | grep 'Got VPN IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()
            node2_ip = node2.succeed("journalctl -u tunnels.service | grep 'Got VPN IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()

            node1.succeed(f"ping -c 3 {node2_ip}")
            node2.succeed(f"ping -c 3 {node1_ip}")

            node1.succeed("ping -c 3 node2.tunnel.internal")
            node2.succeed("ping -c 3 node1.tunnel.internal")
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
            enable = lib.mkEnableOption "tunnels P2P VPN service";

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
              default = "";
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Path to file containing the network password";
            };

            hostname = lib.mkOption {
              type = lib.types.str;
              default = config.networking.hostName;
              description = "Hostname to announce on the VPN";
            };

            dnsPort = lib.mkOption {
              type = lib.types.port;
              default = 6666;
              description = "Port for the local DNS server";
            };

            dns = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Automatically configure systemd-resolved and iptables for DNS resolution";
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
              description = "Tunnels P2P VPN";
              after = [ "network-online.target" ] ++ lib.optional cfg.dns "systemd-resolved.service";
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
                in "${cfg.package}/bin/tunnels -n ${cfg.networkName} -p ${passwordArg} --hostname ${cfg.hostname} --dns-port ${toString cfg.dnsPort}";

                NoNewPrivileges = false;
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
                CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
              };
            };

            # services.resolved = lib.mkIf cfg.dns {
            #   enable = true;
            #   settings.Resolve = {
            #     DNS = [ "127.0.0.1" ];
            #     Domains = [ "~tunnel.internal" ];
            #   };
            # };

            services.resolved = lib.mkIf cfg.dns {
              enable = true;
              domains = [ "~tunnel.internal" ];
              extraConfig = ''
                DNS=127.0.0.1
                Domains=~tunnel.internal
              '';
            };


            networking.firewall.extraCommands = lib.mkIf cfg.dns ''
              iptables -t nat -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j REDIRECT --to-port ${toString cfg.dnsPort}
            '';
          };
        };
    };
}
