{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.earss;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    optional
    optionals
    concatStringsSep
    escapeShellArg
    ;

  loadCredLines =
    optional (cfg.secretKeyBaseFile != null) "secret_key_base:${toString cfg.secretKeyBaseFile}"
    ++ optional (cfg.database.passwordFile != null) "db_password:${toString cfg.database.passwordFile}";

  # Shell fragment: export secrets from systemd LoadCredential into process env.
  exportCredentials = ''
    if [ -n "''${CREDENTIALS_DIRECTORY:-}" ]; then
      if [ -f "$CREDENTIALS_DIRECTORY/secret_key_base" ]; then
        export SECRET_KEY_BASE="$(${pkgs.coreutils}/bin/tr -d '\n' < "$CREDENTIALS_DIRECTORY/secret_key_base")"
      fi
      if [ -f "$CREDENTIALS_DIRECTORY/db_password" ]; then
        db_pass="$(${pkgs.coreutils}/bin/tr -d '\n' < "$CREDENTIALS_DIRECTORY/db_password")"
        export DATABASE_URL="ecto://${cfg.database.user}:''${db_pass}@127.0.0.1/${cfg.database.name}"
      fi
    fi
  '';

  # Peer auth over Unix socket (no DB password). host query is the socket dir.
  peerDatabaseUrl = "ecto://${cfg.database.user}@/${cfg.database.name}?host=${cfg.database.socketDir}";

  earssBin = "${cfg.package}/bin/earss";
in {
  options.services.earss = {
    enable = mkEnableOption "Earss self-hosted feed reader backend";

    package = mkOption {
      type = types.package;
      description = ''
        Mix release package providing `bin/earss`.
        In a host flake: `inputs.earss.packages.''${pkgs.system}.earss`.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "earss";
      description = "System user for the service (match DB role for peer auth).";
    };

    group = mkOption {
      type = types.str;
      default = "earss";
      description = "System group for the service.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/earss";
      description = "Home / working directory for the service user.";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "HTTP port (`PORT`).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open `port` on the firewall. Prefer Tailscale or a reverse proxy.";
    };

    secretKeyBaseFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File containing `SECRET_KEY_BASE` (single line).
        Required unless `environmentFile` already sets `SECRET_KEY_BASE`.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/agenix/earss-env";
      description = ''
        systemd `EnvironmentFile` for secrets/overrides (`SECRET_KEY_BASE`,
        `DATABASE_URL`, poller keys, …). Prefer agenix/sops-nix paths.
      '';
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = {
        POOL_SIZE = "5";
        POLLER_MAX_CONCURRENCY = "3";
        HOST_MAX_CONCURRENT = "2";
      };
      description = "Non-secret environment variables (see `earss.env.example`).";
    };

    database = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable local PostgreSQL, create role/database, install `citext`.
          Default URL uses peer auth on the Unix socket (no password).
        '';
      };

      name = mkOption {
        type = types.str;
        default = "earss";
        description = "Database name.";
      };

      user = mkOption {
        type = types.str;
        default = "earss";
        description = "Database role (should equal `services.earss.user` for peer auth).";
      };

      socketDir = mkOption {
        type = types.str;
        default = "/run/postgresql";
        description = "PostgreSQL Unix socket directory.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          If set, build TCP `DATABASE_URL` with this password instead of peer/socket auth.
        '';
      };
    };

    migrateOnStart = mkOption {
      type = types.bool;
      default = true;
      description = "Run `Earss.Release.migrate()` before start.";
    };

    configureNginx = mkOption {
      type = types.bool;
      default = false;
      description = "Configure an nginx vhost reverse-proxy to Earss.";
    };

    virtualHost = mkOption {
      type = types.str;
      default = "rss.example.com";
      description = "nginx server name when `configureNginx` is enabled.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.environmentFile != null || cfg.secretKeyBaseFile != null;
        message = "services.earss: set secretKeyBaseFile and/or environmentFile with SECRET_KEY_BASE";
      }
      {
        assertion =
          cfg.database.passwordFile != null
          || cfg.environmentFile != null
          || cfg.database.user == cfg.user;
        message = "services.earss: for peer auth, database.user must match services.earss.user (or set passwordFile / DATABASE_URL in environmentFile)";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.${cfg.group} = {};

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [cfg.port];

    services.postgresql = mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [cfg.database.name];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.services.earss-postgres-setup = mkIf cfg.database.createLocally {
      description = "Ensure Earss PostgreSQL citext extension";
      after = ["postgresql.service"];
      requires = ["postgresql.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        RemainAfterExit = true;
        ExecStart = "${config.services.postgresql.package}/bin/psql -d ${escapeShellArg cfg.database.name} -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS citext;'";
      };
    };

    services.nginx = mkIf cfg.configureNginx {
      enable = true;
      virtualHosts.${cfg.virtualHost} = {
        forceSSL = lib.mkDefault true;
        enableACME = lib.mkDefault true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          recommendedProxySettings = true;
        };
      };
    };

    systemd.services.earss = {
      description = "Earss feed reader backend";
      wantedBy = ["multi-user.target"];
      after =
        ["network-online.target"]
        ++ optionals cfg.database.createLocally [
          "postgresql.service"
          "earss-postgres-setup.service"
        ];
      wants = ["network-online.target"];
      requires = optional cfg.database.createLocally "postgresql.service";

      environment =
        {
          PORT = toString cfg.port;
          HOME = cfg.dataDir;
          LANG = "C.UTF-8";
          # Help BEAM / Mix release find a writable tmp if needed
          RELEASE_TMP = "${cfg.dataDir}/tmp";
        }
        // lib.optionalAttrs (
          cfg.database.createLocally && cfg.database.passwordFile == null
        ) {
          DATABASE_URL = peerDatabaseUrl;
        }
        // cfg.settings;

      path = [pkgs.coreutils];

      preStart = ''
        set -euo pipefail
        mkdir -p ${escapeShellArg cfg.dataDir}/tmp
        ${exportCredentials}
        ${lib.optionalString cfg.migrateOnStart ''
          ${earssBin} eval 'Earss.Release.migrate()'
        ''}
      '';

      serviceConfig =
        {
          Type = "exec";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.dataDir;
          Restart = "on-failure";
          RestartSec = "5s";
          TimeoutStartSec = "120s";
          TimeoutStopSec = "60s";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [cfg.dataDir];
          RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
          LockPersonality = true;
          # BEAM + argon2 NIF
          MemoryDenyWriteExecute = false;

          # Wrapper so LoadCredential values become env for the release.
          ExecStart = let
            startScript = pkgs.writeShellScript "earss-start" ''
              set -euo pipefail
              ${exportCredentials}
              exec ${earssBin} start
            '';
          in "${startScript}";

          ExecStop = "${earssBin} stop";
        }
        // lib.optionalAttrs (cfg.environmentFile != null) {
          EnvironmentFile = [cfg.environmentFile];
        }
        // lib.optionalAttrs (loadCredLines != []) {
          LoadCredential = loadCredLines;
        };
    };
  };
}
