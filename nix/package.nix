{
  lib,
  fetchMixDeps,
  mixRelease,
  git,
  cacert,
  # Free-form EARSS_SOURCE_PLUGINS for build-time Mix deps (empty = stock RSS only).
  # Prefer commit/tag pins so the deps FOD hash stays reproducible.
  # Example: "github:ll1zt/earss_source_telegram@a07fe0b947f0dcabc61d40ff85449ebb461ba04e"
  sourcePlugins ? "",
  mixDepsHash,
}:
mixRelease rec {
  pname = "earss";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ../.;
    filter = path: _type: let
      base = baseNameOf path;
    in
      !(builtins.elem base [
          "_build"
          "deps"
          ".git"
          ".elixir_ls"
          ".alma-snapshots"
        ]
        || lib.hasSuffix ".bak" base);
  };

  # mix.exs reads this while resolving deps (and again at compile).
  EARSS_SOURCE_PLUGINS = sourcePlugins;

  mixFodDeps = fetchMixDeps {
    pname = "${pname}-deps";
    inherit version src;
    hash = mixDepsHash;
    inherit EARSS_SOURCE_PLUGINS;
    nativeBuildInputs = [git cacert];
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  };

  nativeBuildInputs = [git cacert];
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  # Mix release scripts do: COOKIE=$(cat "$RELEASE_ROOT/releases/COOKIE")
  # unless RELEASE_COOKIE is set. mixRelease often omits this file in $out.
  # Use postFixup so nothing after install strips it; write under both common layouts.
  postFixup = ''
    write_cookie() {
      local dir="$1"
      mkdir -p "$dir"
      printf '%s\n' 'earss_nix_release' > "$dir/COOKIE"
    }
    if [ -d "$out/releases" ]; then
      write_cookie "$out/releases"
    fi
    # Some mixRelease layouts nest version dirs only
    for d in "$out"/releases/*; do
      if [ -d "$d" ]; then
        write_cookie "$out/releases"
        break
      fi
    done
    # Fallback: ensure path the start script expects exists
    write_cookie "$out/releases"
  '';

  meta = with lib; {
    description = "Self-hosted RSS/Atom/JSON Feed reader backend";
    homepage = "https://github.com/ll1zt/earss";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "earss";
  };
}
