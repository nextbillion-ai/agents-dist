{
  description = "Release binaries of nextbillion-ai/agents-gateway and nextbillion-ai/agents-reviewer, their NixOS modules, and Raft agents' pixel avatars";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The release workflows build static linux/amd64 binaries.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      release = name: builtins.fromJSON (builtins.readFile ./${name}/release.json);
      fetch = r: pkgs.fetchurl { inherit (r) url hash; };

      gateway = release "agents-gateway";
      reviewer = release "agents-reviewer";

      # The gateway runs as git and gh too (by the name it is called with).
      # A Nix build of it has the real git and gh built in; the release
      # binary is told them by its wrapper, which keeps the name it is
      # called with. git-credential runs the unwrapped binary, which gets the
      # same environment from the wrapper it was started under.
      agents-gateway = pkgs.runCommand "agents-gateway-${gateway.version}"
        {
          nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
          passthru.rev = gateway.rev;
          meta.mainProgram = "agents-gateway";
        }
        ''
          install -Dm755 ${fetch gateway} $out/libexec/agents-gateway-bin/agents-gateway
          makeBinaryWrapper $out/libexec/agents-gateway-bin/agents-gateway $out/bin/agents-gateway \
            --inherit-argv0 \
            --set AGENTS_GATEWAY_REAL_GIT ${pkgs.git}/bin/git \
            --set AGENTS_GATEWAY_REAL_GH ${pkgs.gh}/bin/gh
          mkdir -p $out/libexec/agents-gateway
          ln -s $out/bin/agents-gateway $out/libexec/agents-gateway/git
          ln -s $out/bin/agents-gateway $out/libexec/agents-gateway/gh
        '';

      # The reviewer finds git on the service's PATH, which its module sets.
      agents-reviewer = pkgs.runCommand "agents-reviewer-${reviewer.version}"
        {
          passthru.rev = reviewer.rev;
          meta.mainProgram = "agents-reviewer";
        }
        ''
          install -Dm755 ${fetch reviewer} $out/bin/agents-reviewer
        '';

      # The modules are the source repositories' own, which take their
      # flake's self for the default package.
      withPackage = package: { packages.${system}.default = package; };
    in
    {
      packages.${system} = { inherit agents-gateway agents-reviewer; };

      nixosModules = {
        agents-gateway = import ./agents-gateway/module.nix (withPackage agents-gateway);
        agents-reviewer = import ./agents-reviewer/module.nix (withPackage agents-reviewer);
      };
    };
}
