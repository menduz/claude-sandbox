# Claude Code and Codex for Nix

Nix packages of [Claude Code](https://www.anthropic.com/claude-code) and
[Codex](https://github.com/openai/codex), from the release binaries. The
packages have no sandbox: run them in a sandbox of your own (bubblewrap,
gVisor, a virtual machine).

## Packages

- `claude` (`claude.nix`): the native binary of Claude Code. The wrapper
  turns off the auto-updater, the telemetry, the error reports, the feedback
  survey and the other traffic that is not necessary.
- `codex` (`codex.nix`): the Linux package of the release of Codex, with its
  helpers in `libexec/codex`.

```console
$ nix build .#claude
$ nix build .#codex
```

From a different flake, without the inputs of this flake:

```nix
claude = pkgs.callPackage "${inputs.claude-sandbox}/claude.nix" { };
codex = pkgs.callPackage "${inputs.claude-sandbox}/codex.nix" { };
```

Claude Code is unfree: set `nixpkgs.config.allowUnfree`.

## Updates

- `nix run .#update-claude`: the latest version of Claude Code.
- `./update-codex.sh`: the latest version of Codex.
