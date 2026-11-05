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

      # The CA is deliberately not generated here. A CA generated inside a
      # derivation puts its private key in the world-readable store, and since
      # the output is not reproducible, machines sharing a store path (remote
      # builds, `nix copy`, binary caches) end up trusting each other's CA
      # instead of their own. Each machine generates its CA in
      # ~<user>/.puma-dev-ssl and passes only the public cert in as
      # `caCertificate` (see README).
      nixosModule = { config, lib, pkgs, ... }:
        let
          cfg   = config.services.puma-dev;
          pkg   = mkPumaDev pkgs;
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

            caCertificate = lib.mkOption {
              type    = lib.types.nullOr lib.types.path;
              default = null;
              example = lib.literalExpression "./puma-dev/myhost.pem";
              description = ''
                Public certificate (PEM) of the CA puma-dev signs its certs with,
                trusted system-wide and by Firefox. It must be the cert in
                ~<user>/.puma-dev-ssl/cert.pem, next to its key.pem, which never
                enter the Nix store. When null, nothing is trusted and browsers
                reject puma-dev's certs.
              '';
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

            warnings = lib.optional (cfg.caCertificate == null)
              "services.puma-dev.caCertificate is not set, so puma-dev's HTTPS certs will not be trusted.";

            # The CA is generated outside Nix, so all activation can do is
            # point out when the trusted cert isn't the one puma-dev uses.
            system.activationScripts."puma-dev-ssl" = lib.mkIf (cfg.caCertificate != null) {
              text = ''
                if ! ${pkgs.diffutils}/bin/cmp -s ${cfg.caCertificate} ${homeDir}/.puma-dev-ssl/cert.pem; then
                  echo "warning: ${homeDir}/.puma-dev-ssl/cert.pem is missing or differs from services.puma-dev.caCertificate; puma-dev's HTTPS certs will not be trusted." >&2
                fi
              '';
            };

            # Trust the CA cert system-wide: curl, wget, Chrome, Brave, etc.
            security.pki.certificateFiles = lib.optional (cfg.caCertificate != null) cfg.caCertificate;

            # Firefox maintains its own NSS store; install via policy.
            programs.firefox.policies.Certificates.Install = lib.optional (cfg.caCertificate != null) "${cfg.caCertificate}";

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
              # puma-dev loads its CA at startup, so restart it on a new one.
              restartTriggers = lib.optional (cfg.caCertificate != null) cfg.caCertificate;

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
