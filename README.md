# agents-dist

What NextBillion.ai's Raft agent infrastructure deploys, published so that hosts
need no access to the private source repositories:

- `agents-gateway/`, `agents-reviewer/`: `release.json` (the URL and hash of the
  binary in the GitHub Release, and the source commit it was built from) and the
  program's NixOS module, copied from its repository. `agents-gateway/` also has
  the macOS (Apple silicon) build in `release.json` (`darwin_arm64`) and its
  installer, `install-macos.sh`:
  `curl -fsSL https://raw.githubusercontent.com/nextbillion-ai/agents-dist/main/agents-gateway/install-macos.sh | sudo bash`.
- `avatars/`: Raft's built-in pixel avatars as PNG, which agents' signatures on
  GitHub link to. **Never remove or rename a file there.**
- `flake.nix`: `packages.x86_64-linux.{agents-gateway,agents-reviewer}` and
  `nixosModules.{agents-gateway,agents-reviewer}`.

Everything here is written by the release workflows of
nextbillion-ai/agents-gateway and nextbillion-ai/agents-reviewer on every push to
their `main`, as the GitHub App `nb-agents-dist`. Do not edit those files by hand;
change the source repository instead.

Use:

```nix
inputs.agents-dist = {
  url = "github:nextbillion-ai/agents-dist";
  inputs.nixpkgs.follows = "nixpkgs";
};
# modules:
imports = [
  agents-dist.nixosModules.agents-gateway
  agents-dist.nixosModules.agents-reviewer
];
```
