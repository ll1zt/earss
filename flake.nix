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
  in {
    packages = forAllSystems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          # Avoid accidental unfree deps in CI/eval.
          config.allowUnfree = false;
        };

        # OTP 27 + Elixir 1.18 is a common stable pair; fall back if renamed.
        beamPackages =
          if pkgs.beam.packages ? erlang_27
          then
            pkgs.beam.packages.erlang_27.extend (
              _final: prev: {
                elixir = prev.elixir_1_18 or prev.elixir;
              }
            )
          else pkgs.beamPackages;

        # Refresh whenever mix.lock or sourcePlugins changes (nix build .#earss).
        mixDepsHash = "sha256-fBUkw9ONvDES6fNIUYd2O8VdlsQSNoaFEinI+XCNPkA=";

        # Stock release = RSS/Atom/JSON only (recommended default for NixOS).
        # Optional plugins: pin commits (not @main), then refresh mixDepsHash.
        # Example:
        # sourcePlugins = "github:ll1zt/earss_source_telegram@a07fe0b947f0dcabc61d40ff85449ebb461ba04e";
        # Multiple: comma-separated specs (same grammar as EARSS_SOURCE_PLUGINS).
        sourcePlugins = "";
      in {
        earss = pkgs.callPackage ./nix/package.nix {
          inherit (beamPackages) fetchMixDeps mixRelease;
          inherit mixDepsHash sourcePlugins;
        };
        default = self.packages.${system}.earss;
      }
    );

    nixosModules = {
      default = self.nixosModules.earss;
      earss = import ./nix/module.nix;
    };

    # Eval-only smoke test of the module (no real release build).
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
              # Keep check light
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
