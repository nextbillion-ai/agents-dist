# NixOS module: the gateway daemon plus the git/gh wrappers for agent accounts.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.nextbillion-agents-gateway;

  # In the service's own runtime directory, so that gateways of different
  # service accounts (e.g. another fork) can run on one host.
  socket = "/run/${cfg.user}/gateway.sock";

  # bin/git and bin/gh, so a user profile can put the wrappers on PATH. They
  # run the program under those names and tell it the daemon's socket,
  # unless AGENTS_GATEWAY_SOCKET is set already: the end-to-end tests run
  # their own daemon, and their git finds these wrappers on PATH.
  wrappers = pkgs.runCommand "agents-gateway-wrappers" { nativeBuildInputs = [ pkgs.makeBinaryWrapper ]; } ''
    mkdir -p $out/bin
    for name in git gh; do
      makeBinaryWrapper ${cfg.package}/bin/agents-gateway $out/bin/$name \
        --argv0 $name --set-default AGENTS_GATEWAY_SOCKET ${socket}
    done
  '';
in
{
  options.services.nextbillion-agents-gateway = {
    enable = lib.mkEnableOption "agents-gateway, which takes over agents' GitHub actions";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "agents-gateway.packages.\${system}.default";
      description = "The agents-gateway package.";
    };

    appId = lib.mkOption {
      type = lib.types.str;
      example = "123456";
      description = "GitHub App ID (or client ID) the gateway issues installation tokens for.";
    };

    installation = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nextbillion-ai";
      description = ''
        Account or organization whose installation of the App to use. Needed
        only when the App is installed on several accounts; by default the
        App's only installation is used.
      '';
    };

    commitEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "agents@nextbillion.ai";
      description = ''
        Email used for all agents' commits (the author name stays the agent's
        name). Its Gravatar is shown on those commits and in agents'
        signatures. Must not be added to any GitHub account. By default each
        agent gets an address under raft-agents.invalid.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "agents-gateway";
      example = "nextbillion-agents-gateway";
      description = ''
        System account the daemon runs as, and the name of its systemd service.
        The account is created by this module, cannot log in, and owns the
        state directory `/var/lib/<user>`.
      '';
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        The GitHub App private key on the host, owned by the service account
        with mode 0600. Copied there by hand; it never enters Git or the Nix
        store. The service does not start until the file exists.
      '';
    };

    webhookListen = lib.mkOption {
      type = lib.types.str;
      example = "127.0.0.1:8791";
      description = ''
        Address the daemon receives the App's webhook deliveries on (merged
        pull requests are told to the agent named by their agent:<name>
        label). Making it reachable from GitHub (e.g. a Tailscale Funnel to a
        loopback address) is up to the host.
      '';
    };

    githubWebhookSecretFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/nextbillion-agents-gateway/github-webhook-secret";
      description = "The App's webhook secret, owned by the service account with mode 0600. The service does not start until the file exists.";
    };

    raftAppConfigFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/nextbillion-agents-gateway/raft-app.json";
      description = ''
        Credentials of the Raft App that tells agents about events: JSON with
        `client_id`, `client_secret` and `server_slug`, owned by the service
        account with mode 0600. The service does not start until the file
        exists.
      '';
    };


    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "raft-nextbillion" ];
      description = ''
        Accounts whose agents use the gateway. Only these users may request
        tokens, and their git and gh are replaced by the wrappers.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !lib.hasPrefix "/nix/store" cfg.privateKeyFile;
        message = "services.nextbillion-agents-gateway.privateKeyFile must not be in the Nix store.";
      }
    ];

    users.users = lib.genAttrs cfg.users (_: {
      # The per-user profile precedes the system profile on PATH.
      packages = [ (lib.hiPrio wrappers) ];
    }) // {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.user;
        description = "agents-gateway daemon";
      };
    };
    users.groups.${cfg.user} = { };

    # StateDirectory is only created when the service starts, and it does not
    # start before the key exists: create the directory at activation so the
    # key can be installed into it.
    systemd.tmpfiles.rules = [ "d /var/lib/${cfg.user} 0700 ${cfg.user} ${cfg.user} -" ];

    # Named after the account, so `systemctl status <user>` and
    # `journalctl -u <user>` find it.
    systemd.services.${cfg.user} = {
      description = "Gateway for AI agents' GitHub actions";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # Until the key and secrets have been copied in, stay inactive instead of failing in a loop.
      unitConfig.ConditionPathExists = [ cfg.privateKeyFile cfg.githubWebhookSecretFile cfg.raftAppConfigFile ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/agents-gateway"
            "serve"
            "--socket"
            socket
            "--app-id"
            cfg.appId
            "--private-key-file"
            cfg.privateKeyFile
            "--webhook-listen"
            cfg.webhookListen
            "--webhook-secret-file"
            cfg.githubWebhookSecretFile
            "--raft-app-file"
            cfg.raftAppConfigFile
          ]
          ++ lib.optionals (cfg.installation != null) [ "--installation" cfg.installation ]
          ++ lib.optionals (cfg.commitEmail != null) [ "--commit-email" cfg.commitEmail ]
          ++ lib.concatMap (u: [ "--allow-user" u ]) cfg.users
        );
        Restart = "on-failure";
        RestartSec = "5s";

        User = cfg.user;
        Group = cfg.user;
        StateDirectory = cfg.user;
        StateDirectoryMode = "0700";
        RuntimeDirectory = cfg.user;
        RuntimeDirectoryMode = "0755"; # clients must reach the socket; access is checked per peer UID
        UMask = "0077";

        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
      };
    };
  };
}
