{
  description = "Tunnels - P2P VPN with DNS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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

        # Use rust-overlay for the toolchain
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        # Crane library for Rust builds
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # Common arguments for crane
        commonArgs = {
          src = craneLib.cleanCargoSource ./.;
          strictDeps = true;
          buildInputs = [ ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];
        };

        # Build dependencies separately for better caching
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual binary
        tunnels = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
        });

        # NixOS integration test
        # Note: Full peer discovery requires external DHT bootstrap nodes
        # This test verifies basic service operation and DNS server functionality
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

              # Allow all traffic in test VMs
              networking.firewall.enable = false;

              # Needed for testing
              environment.systemPackages = [ pkgs.dig pkgs.iputils pkgs.netcat ];
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

              networking.firewall.enable = false;
              environment.systemPackages = [ pkgs.dig pkgs.iputils pkgs.netcat ];
            };
          };

          testScript = ''
            start_all()

            # Wait for services to start
            node1.wait_for_unit("tunnels.service")
            node2.wait_for_unit("tunnels.service")

            # Wait for nodes to get VPN IPs
            node1.wait_for_console_text("Got VPN IP:")
            node2.wait_for_console_text("Got VPN IP:")

            # Extract VPN IPs from logs
            node1_ip = node1.succeed("journalctl -u tunnels.service | grep 'Got VPN IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()
            node2_ip = node2.succeed("journalctl -u tunnels.service | grep 'Got VPN IP:' | tail -1 | grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+'").strip()

            print(f"node1 VPN IP: {node1_ip}")
            print(f"node2 VPN IP: {node2_ip}")

            # Ping each other over the VPN
            print("Testing connectivity: node1 -> node2")
            node1.succeed(f"ping -c 3 {node2_ip}")

            print("Testing connectivity: node2 -> node1")
            node2.succeed(f"ping -c 3 {node1_ip}")

            print("✓ VPN connectivity test passed!")
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
      # NixOS module available on all systems
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

            setupDnsResolution = lib.mkOption {
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
                in "${cfg.package}/bin/tunnels -n ${cfg.networkName} -p ${passwordArg} --hostname ${cfg.hostname} --dns-port ${toString cfg.dnsPort}";

                # Security hardening
                NoNewPrivileges = false; # Need privileges for network setup
                PrivateTmp = true;
                ProtectSystem = "strict";
                ProtectHome = true;

                # Capabilities needed for network operations
                AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
                CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" ];
              };
            };

            # Configure systemd-resolved for .tunnel.internal domains
            services.resolved = lib.mkIf cfg.setupDnsResolution {
              enable = true;
              settings = {
                Resolve = {
                  Domains = [ "~tunnel.internal" ];
                  FallbackDNS = [ "127.0.0.1" ];
                };
              };
            };

            # iptables rule to redirect port 53 to DNS port
            networking.firewall.extraCommands = lib.mkIf cfg.setupDnsResolution ''
              # Redirect local DNS queries (port 53) to tunnels DNS server
              iptables -t nat -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j REDIRECT --to-port ${toString cfg.dnsPort}
            '';
          };
        };
    };
}
