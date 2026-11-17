self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.nextbillion-agents-reviewer;
  # The account's home, set like any account's (users.users.<user>.home).
  home = config.users.users.${cfg.user}.home;
  # Files kept outside Git and the Nix store (owned by the account, mode
  # 0600): the App's private key and webhook secret, put there by hand (the
  # service does not start until both exist), and the env file with
  # optional environment variables such as CLAUDE_CODE_OAUTH_TOKEN for the
  # Claude runner.
  configDir = "${home}/.config/agents-reviewer";
  privateKeyFile = "${configDir}/github-app-private-key.pem";
  webhookSecretFile = "${configDir}/github-webhook-secret";
  # Same convention as the Raft accounts' ~/.config/raft-computer/raft-computer.env.
  envFile = "${configDir}/agents-reviewer.env";
  configFile = pkgs.writeText "agents-reviewer.json" (builtins.toJSON {
    app_id = cfg.appId;
    installation = cfg.installation;
    private_key_file = privateKeyFile;
  });
in
{
  options.services.nextbillion-agents-reviewer = {
    enable = lib.mkEnableOption "the agents-reviewer daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "agents-reviewer";
      description = "The agents-reviewer package.";
    };

    appId = lib.mkOption {
      type = lib.types.str;
      description = "ID of the reviewer's GitHub App.";
    };

    installation = lib.mkOption {
      type = lib.types.str;
      example = "nextbillion-ai";
      description = "Account or organization whose installation of the App to use.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "agents-reviewer";
      description = ''
        Account that runs the daemon and the review sessions. Admins log the
        agent tools in as it (`sudo -iu <user>`, then `codex login`, …).
        Its home, set by the host in `users.users.<user>.home`, is also the
        daemon's state directory: the database, working copies, and the
        agents' logins and sessions, which are kept and keep growing.
      '';
    };


    keepWorkdir = lib.mkOption {
      type = lib.types.str;
      default = "168h";
      description = "Keep a pull request's working copy this long after it is closed (Go duration). Records are kept for good.";
    };

    runner = lib.mkOption {
      type = lib.types.enum [ "codex" "claude" ];
      default = "codex";
      description = ''
        Runner for new reviews. A pull request keeps the runner its session
        started with (sessions cannot move between them), so switching only
        affects reviews started afterwards.
      '';
    };

    codex = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.codex;
        defaultText = lib.literalExpression "pkgs.codex";
        description = "The Codex CLI.";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "o3";
        description = "Model (`codex -m`); null for Codex's default. Recorded per round.";
      };
      reasoningEffort = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "high";
        description = "Reasoning effort (`model_reasoning_effort`); null for Codex's default. Recorded per round.";
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "--dangerously-bypass-approvals-and-sandbox" ];
        description = ''
          Extra options for `codex exec` and `codex exec resume`. Codex's own
          sandbox is bypassed by default: the session needs the network for
          the GitHub API, and the systemd service already confines it.
        '';
      };
    };

    claude = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.runner == "claude";
        defaultText = lib.literalExpression ''runner == "claude"'';
        description = "Make Claude Code available to review sessions (needed while any review uses it).";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.claude-code;
        defaultText = lib.literalExpression "pkgs.claude-code";
        description = "Claude Code.";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "opus";
        description = "Model (`--model`); null for Claude Code's default. Recorded per round.";
      };
      effort = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "low" "medium" "high" "xhigh" "max" ]);
        default = null;
        description = "Effort (`--effort`); null for the default. Recorded per round.";
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "--dangerously-skip-permissions" ];
        description = "Extra options for `claude -p`. Permission prompts are skipped by default, as nobody could answer them.";
      };
    };

    webhookListen = lib.mkOption {
      type = lib.types.str;
      example = "127.0.0.1:8790";
      description = ''
        Address the daemon receives the App's webhook deliveries on. Making
        it reachable from GitHub (e.g. a Tailscale Funnel to a loopback
        address) is up to the host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.runner != "claude" || cfg.claude.enable;
        message = "services.nextbillion-agents-reviewer: runner = \"claude\" needs claude.enable";
      }
    ];

    # A system account with a shell and the agent tools, so that admins can
    # `sudo -iu` in and log the tools in their own ways.
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      description = "agents-reviewer";
      createHome = true;
      homeMode = "0700";
      shell = pkgs.bashInteractive;
      hashedPassword = "!";
      packages = [ cfg.package cfg.codex.package pkgs.git ] ++ lib.optional cfg.claude.enable cfg.claude.package;
    };
    users.groups.${cfg.user} = { };

    environment.etc."agents-reviewer/config.json".source = configFile;

    # Where the private key is copied to, and the env file: created empty
    # (0600) if missing, existing contents kept.
    systemd.tmpfiles.settings."10-agents-reviewer" = {
      "${home}/.config".d = { user = cfg.user; group = cfg.user; mode = "0700"; };
      ${configDir}.d = { user = cfg.user; group = cfg.user; mode = "0700"; };
      ${envFile}.f = { user = cfg.user; group = cfg.user; mode = "0600"; };
    };

    # The account's login shell loads the env file too, so `sudo -iu` shells
    # use what the service uses (e.g. CLAUDE_CODE_OAUTH_TOKEN).
    programs.bash.loginShellInit = ''
      if [ "$(id -un)" = ${lib.escapeShellArg cfg.user} ] && [ -r ${lib.escapeShellArg envFile} ]; then
        set -a
        . ${lib.escapeShellArg envFile}
        set +a
      fi
    '';

    systemd.services.${cfg.user} = {
      description = "agents-reviewer";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig.ConditionPathExists = [ privateKeyFile webhookSecretFile ];
      # Review sessions run the tool, git and the usual shell utilities.
      path = [ cfg.package cfg.codex.package pkgs.git pkgs.ripgrep ] ++ lib.optional cfg.claude.enable cfg.claude.package;
      environment = {
        HOME = home;
        AGENTS_REVIEWER_CONFIG = "/etc/agents-reviewer/config.json";
      };
      serviceConfig = {
        User = cfg.user;
        Group = cfg.user;
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/agents-reviewer"
            "serve"
            "--config" "/etc/agents-reviewer/config.json"
            "--state-dir" home
            "--runner" cfg.runner
            "--codex" "${cfg.codex.package}/bin/codex"
            "--webhook-listen" cfg.webhookListen
            "--webhook-secret-file" webhookSecretFile
            "--keep-workdir" cfg.keepWorkdir
          ]
          ++ lib.optionals (cfg.codex.model != null) [ "--codex-model" cfg.codex.model ]
          ++ lib.optionals (cfg.codex.reasoningEffort != null) [ "--codex-effort" cfg.codex.reasoningEffort ]
          ++ lib.concatMap (a: [ "--codex-arg=${a}" ]) cfg.codex.args
          ++ lib.optionals cfg.claude.enable (
            [ "--claude" "${cfg.claude.package}/bin/claude" ]
            ++ lib.optionals (cfg.claude.model != null) [ "--claude-model" cfg.claude.model ]
            ++ lib.optionals (cfg.claude.effort != null) [ "--claude-effort" cfg.claude.effort ]
            ++ lib.concatMap (a: [ "--claude-arg=${a}" ]) cfg.claude.args
          )
        );
        EnvironmentFile = "-${envFile}";
        Restart = "always";
        RestartSec = 10;
        WorkingDirectory = home;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only"; # in case home is under /home
        ReadWritePaths = [ home ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}
