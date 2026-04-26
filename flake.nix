{
  description = "puma-dev — zero-config Rack/Rails development server with .test domains";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      version = "0.18.3";

      # Uses the upstream pre-built Linux binary rather than building from source.
      # Building from source requires working around a go.mod/vendor compatibility
      # issue (go 1.13 directive vs Go 1.21+ strict lang enforcement) that is
      # non-trivial to patch cleanly in Nix.
      mkPumaDev = pkgs: pkgs.stdenv.mkDerivation {
        pname = "puma-dev";
        inherit version;

        src = pkgs.fetchurl {
          url  = "https://github.com/puma/puma-dev/releases/download/v${version}/puma-dev-${version}-linux-amd64.tar.gz";
          hash = "sha256-+Bejj7cTjgAIkj+ZRhK97Q5uVeaXVfCL4LZhuJa0etI=";
        };

        nativeBuildInputs = [ pkgs.autoPatchelfHook ];

        # The tarball contains just the binary with no wrapper directory.
        sourceRoot = ".";

        installPhase = ''
          install -Dm755 puma-dev $out/bin/puma-dev
        '';

        meta = with pkgs.lib; {
          description = "Zero-config Rack/Rails dev server with .test domains and automatic HTTPS";
          homepage    = "https://github.com/puma/puma-dev";
          license     = licenses.mit;
          mainProgram = "puma-dev";
          platforms   = platforms.linux;
          sourceProvenance = [ sourceTypes.binaryNativeCode ];
        };
      };

      # Generates a self-signed CA certificate at build time via openssl.
      # The result ($out/cert.pem, $out/key.pem) is deployed to ~/.puma-dev-ssl/
      # by the activation script so puma-dev uses it instead of generating its own
      # (puma-dev's self-generated cert leaves CACert nil, breaking HTTPS).
      mkPumaDevCerts = pkgs: pkgs.runCommand "puma-dev-certs" {
        nativeBuildInputs = [ pkgs.openssl ];
      } ''
        mkdir -p "$out"
        openssl req \
          -new -newkey rsa:2048 \
          -days 3650 \
          -nodes \
          -x509 \
          -subj "/CN=puma-dev CA" \
          -addext "basicConstraints=critical,CA:TRUE" \
          -addext "keyUsage=critical,keyCertSign,cRLSign" \
          -keyout "$out/key.pem" \
          -out    "$out/cert.pem"
      '';

      nixosModule = { config, lib, pkgs, ... }:
        let
          cfg   = config.services.puma-dev;
          pkg   = mkPumaDev pkgs;
          certs = mkPumaDevCerts pkgs;
        in {
          options.services.puma-dev = {
            enable = lib.mkEnableOption "puma-dev development server";

            user = lib.mkOption {
              type        = lib.types.str;
              description = "User account that owns the puma-dev process and whose home directory holds app symlinks.";
            };

            dir = lib.mkOption {
              type    = lib.types.str;
              default = "%h/.puma-dev";
              description = "Directory where app symlinks live (systemd home specifier %h ok).";
            };

            domains = lib.mkOption {
              type    = lib.types.listOf lib.types.str;
              default = [ "test" ];
              description = "TLDs that puma-dev responds to.";
            };

            httpPort = lib.mkOption {
              type    = lib.types.port;
              default = 9280;
              description = "HTTP port puma-dev listens on (must be unprivileged; port 80 is forwarded here via nftables).";
            };

            httpsPort = lib.mkOption {
              type    = lib.types.port;
              default = 9283;
              description = "HTTPS port puma-dev listens on.";
            };

            idleTimeout = lib.mkOption {
              type    = lib.types.str;
              default = "15m";
              description = "How long before an idle app is stopped (e.g. 15m, 1h).";
            };
          };

          config = lib.mkIf cfg.enable (
            let
              homeDir = "/home/${cfg.user}";
              # Expand %h at Nix evaluation time so the unit file contains the
              # literal path; avoids systemd specifier resolution issues with
              # system services running as a non-root user.
              appDir = lib.replaceStrings [ "%h" ] [ homeDir ] cfg.dir;
            in {
            environment.systemPackages = [ pkg ];

            # nftables + firewall must be active for the redirect rules below.
            networking.nftables.enable = lib.mkDefault true;
            networking.firewall.enable = lib.mkDefault true;

            # Deploy the generated cert/key to ~/.puma-dev-ssl/ so puma-dev uses the trusted CA on startup.
            system.activationScripts."puma-dev-ssl" = {
              text = ''
                dir=/home/${cfg.user}/.puma-dev-ssl
                mkdir -p "$dir"
                install -m 644 ${certs}/cert.pem "$dir/cert.pem"
                install -m 600 ${certs}/key.pem  "$dir/key.pem"
                chown -R ${cfg.user} "$dir"
              '';
            };

            # Trust the CA cert system-wide: curl, wget, Chrome, Brave, etc.
            security.pki.certificateFiles = [ "${certs}/cert.pem" ];

            # Firefox maintains its own NSS store; install via policy.
            programs.firefox.policies.Certificates.Install = [ "${certs}/cert.pem" ];

            # puma-dev on Linux has no DNS stub, so we run a minimal dnsmasq
            # instance on port 9253 that answers *.test → 127.0.0.1.
            services.dnsmasq = {
              enable              = lib.mkDefault true;
              resolveLocalQueries = false;  # don't touch /etc/resolv.conf
              settings = {
                port           = 9253;
                listen-address = "127.0.0.1";
                no-resolv      = true;
                no-hosts       = true;
                address        = map (d: "/.${d}/127.0.0.1") cfg.domains;
              };
            };

            # Configure systemd-resolved to forward configured domains to the
            # dnsmasq stub above (port 9253).
            services.resolved = {
              enable   = lib.mkDefault true;
              settings.Resolve = {
                DNS     = "127.0.0.1:9253";
                Domains = lib.concatMapStringsSep " " (d: "~${d}") cfg.domains;
              };
            };

            systemd.services."puma-dev" = {
              description = "puma-dev Rack/Rails development server";
              wantedBy    = [ "multi-user.target" ];
              after       = [ "network.target" ];

              serviceConfig = {
                User         = cfg.user;
                ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${appDir}";
                ExecStart = lib.concatStringsSep " " [
                  "${pkg}/bin/puma-dev"
                  "-dir"        appDir
                  "-http-port"  (toString cfg.httpPort)
                  "-https-port" (toString cfg.httpsPort)
                  "-timeout"    cfg.idleTimeout
                  "-d"          (lib.concatStringsSep ":" cfg.domains)
                ];
                Restart    = "on-failure";
                RestartSec = "5s";
              };

              environment.HOME = homeDir;
            };

            # Scoped port forwarding: redirect :80→httpPort and :443→httpsPort
            # only when the destination is a local address, so external HTTPS
            # traffic is never affected.
            # Uses networking.nftables.tables (not .ruleset) so this table is
            # merged into the NixOS-managed nftables config rather than written
            # to a separate file that would race with the firewall service.
            networking.nftables.tables.puma_dev = {
              family = "inet";
              content = ''
                chain output {
                  type nat hook output priority dstnat; policy accept;
                  ip daddr 127.0.0.0/8 tcp dport 443 redirect to :${toString cfg.httpsPort}
                  ip daddr 127.0.0.0/8 tcp dport 80  redirect to :${toString cfg.httpPort}
                  ip6 daddr ::1       tcp dport 80  redirect to :${toString cfg.httpPort}
                }
              '';
            };
          });
        };

    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs     = nixpkgs.legacyPackages.${system};
        puma-dev = mkPumaDev pkgs;
      in {
        packages.puma-dev = puma-dev;
        packages.default  = puma-dev;
        devShells.default = pkgs.mkShell { packages = [ puma-dev ]; };
      }
    ) // {
      nixosModules.default  = nixosModule;
      nixosModules.puma-dev = nixosModule;
    };
}
