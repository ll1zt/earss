{
  description = "Earss — self-hosted feed reader backend (Mix release + NixOS module)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs systems;

    # Beam toolchain used by stock packages and by lib.mkEarss.
    mkBeamPackages = pkgs:
      if pkgs.beam.packages ? erlang_27
      then
        pkgs.beam.packages.erlang_27.extend (
          _final: prev: {
            elixir = prev.elixir_1_18 or prev.elixir;
          }
        )
      else pkgs.beamPackages;

    # Build an Earss Mix release. Deployments that want plugins should call this
    # from the *host* flake (nix-config) — not fork this default package.
    #
    #   earss.lib.mkEarss {
    #     inherit pkgs;
    #     sourcePlugins = "github:you/plugin@deadbeef";
    #     translatePlugins = "github:ll1zt/earss_translate_openai@main";
    #     ttsPlugins = "github:ll1zt/earss_tts_podcast@main";
    #     mixDepsHash = "sha256-…";  # nix build after changing plugins
    #   }
    mkEarss = {
      pkgs,
      sourcePlugins ? "",
      translatePlugins ? "",
      ttsPlugins ? "",
      mixDepsHash,
      beamPackages ? null,
    }: let
      bp = if beamPackages != null then beamPackages else mkBeamPackages pkgs;
    in
      pkgs.callPackage ./nix/package.nix {
        inherit (bp) fetchMixDeps mixRelease;
        inherit sourcePlugins translatePlugins ttsPlugins mixDepsHash;
      };

    # Stock release: native RSS/Atom/JSON only (no optional source plugins).
    # Hash is for empty EARSS_SOURCE_PLUGINS; refresh if mix.lock changes.
    stockMixDepsHash = "sha256-l4194tMSkEe4UxMGTFT+4VnxMKoHAVh7B/S4358hlww=";
  in {
    # Host flakes: earss.lib.mkEarss { inherit pkgs; sourcePlugins = "…"; mixDepsHash = "…"; }
    lib = {
      inherit mkEarss mkBeamPackages;
    };

    packages = forAllSystems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = false;
        };
      in {
        # Default / upstream package: stock only. Plugins live in the deployer's flake.
        earss = mkEarss {
          inherit pkgs;
          sourcePlugins = "";
          mixDepsHash = stockMixDepsHash;
        };
        default = self.packages.${system}.earss;
      }
    );

    nixosModules = {
      default = self.nixosModules.earss;
      earss = import ./nix/module.nix;
    };

    checks = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        dummy = pkgs.writeShellScriptBin "earss" ''
          case "''${1:-}" in
            start) exec ${pkgs.coreutils}/bin/sleep infinity ;;
            stop) exit 0 ;;
            eval) exit 0 ;;
            *) exit 0 ;;
          esac
        '';
      in {
        module = (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.earss
            {
              nixpkgs.pkgs = pkgs;
              services.earss = {
                enable = true;
                package = dummy;
                secretKeyBaseFile = pkgs.writeText "skb" "module-eval-only-secret-key-base-not-for-production-use-xx";
                database.createLocally = false;
                migrateOnStart = false;
              };
              boot.isContainer = true;
              networking.hostName = "earss-module-check";
              system.stateVersion = "25.11";
            }
          ];
        }).config.system.build.toplevel;
      }
    );

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);
  };
}
