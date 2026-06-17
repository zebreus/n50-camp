{
  description = "n50-camp — the static event site (tent viewer) plus a hardened static HTTP server to serve it";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Overlay that adds both packages to pkgs.
      overlays.default = final: prev: {
        # The built static website. `astro build` emits plain HTML/CSS into
        # dist/ (the site ships zero JavaScript), which we copy verbatim to $out.
        n50-camp = final.buildNpmPackage {
          pname = "n50-camp";
          version = "0.2.0";

          # Flakes copy the git tree, so node_modules/, dist/ and .astro/ (all
          # gitignored) are excluded automatically.
          src = ./.;

          npmDepsHash = "sha256-HnEb2DXpO/Se/9NBRFp1i1V/jze70pi8Dhwkndo/lF0=";

          # Fully offline, deterministic build.
          env.ASTRO_TELEMETRY_DISABLED = "1";

          # This is a static site, not an npm library: skip the default
          # node_modules install and just keep the rendered output.
          dontNpmInstall = true;
          installPhase = ''
            runHook preInstall
            cp -r dist "$out"
            runHook postInstall
          '';

          meta = {
            description = "Static n50-camp event website";
            platforms = lib.platforms.all;
          };
        };

        # A deliberately tiny, locked-down static file server that serves ONLY
        # the n50-camp site. The site root is baked in, so it cannot be pointed
        # at arbitrary paths; static-web-server itself does no directory
        # listing and refuses path traversal. Real filesystem isolation is
        # added by the NixOS module's systemd sandbox.
        n50-camp-server = final.writeShellApplication {
          name = "n50-camp-server";
          runtimeInputs = [ final.static-web-server ];
          text = ''
            exec static-web-server \
              --root "${final.n50-camp}" \
              --host "''${N50_CAMP_HOST:-::}" \
              --port "''${N50_CAMP_PORT:-8080}" \
              --directory-listing false \
              --log-level "''${N50_CAMP_LOG_LEVEL:-info}" \
              "$@"
          '';
        };
      };

      packages = forAllSystems (
        pkgs:
        let
          ext = pkgs.extend self.overlays.default;
        in
        {
          inherit (ext) n50-camp n50-camp-server;
          default = ext.n50-camp-server;
        }
      );

      # NixOS module: applies the overlay and runs the server as a hardened,
      # sandboxed systemd service.
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.n50-camp;
        in
        {
          options.services.n50-camp = {
            enable = lib.mkEnableOption "the n50-camp static website server";

            package = lib.mkOption {
              type = lib.types.package;
              default = pkgs.n50-camp-server;
              defaultText = lib.literalExpression "pkgs.n50-camp-server";
              description = "The static-server package to run.";
            };

            host = lib.mkOption {
              type = lib.types.str;
              default = "::";
              example = "127.0.0.1";
              description = "Address to bind to. Defaults to all interfaces (IPv4 + IPv6).";
            };

            port = lib.mkOption {
              type = lib.types.port;
              default = 8080;
              description = "TCP port to listen on.";
            };

            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Open {option}`port` in the firewall.";
            };
          };

          config = lib.mkIf cfg.enable {
            nixpkgs.overlays = [ self.overlays.default ];

            networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

            systemd.services.n50-camp = {
              description = "n50-camp static website";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              environment = {
                N50_CAMP_HOST = cfg.host;
                N50_CAMP_PORT = toString cfg.port;
              };

              serviceConfig = {
                ExecStart = lib.getExe cfg.package;
                Restart = "on-failure";

                # Run as a transient, unprivileged user.
                DynamicUser = true;

                # Filesystem: the process gets no writable or readable access to
                # anything outside the (read-only) nix store. "only http".
                ProtectSystem = "strict";
                ProtectHome = true;
                PrivateTmp = true;
                PrivateDevices = true;
                ProtectProc = "invisible";
                ProcSubset = "pid";
                UMask = "0077";

                # Privilege / namespace lockdown.
                NoNewPrivileges = true;
                RestrictNamespaces = true;
                LockPersonality = true;
                MemoryDenyWriteExecute = true;
                RestrictRealtime = true;
                RestrictSUIDSGID = true;
                ProtectControlGroups = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectKernelLogs = true;
                ProtectClock = true;
                ProtectHostname = true;
                RemoveIPC = true;

                # Networking: HTTP over IP only.
                RestrictAddressFamilies = [
                  "AF_INET"
                  "AF_INET6"
                ];

                # Drop all capabilities, granting only the bind capability when a
                # privileged (<1024) port is requested.
                CapabilityBoundingSet = lib.optionals (cfg.port < 1024) [ "CAP_NET_BIND_SERVICE" ];
                AmbientCapabilities = lib.optionals (cfg.port < 1024) [ "CAP_NET_BIND_SERVICE" ];

                # Syscall allow-list.
                SystemCallArchitectures = "native";
                SystemCallFilter = [
                  "@system-service"
                  "~@privileged"
                  "~@resources"
                ];
              };
            };
          };
        };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nodejs
            pkgs.static-web-server
          ];
        };
      });
    };
}
