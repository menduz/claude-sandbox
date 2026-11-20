{
  description = "Claude Code and Codex, without a sandbox: run them in a sandbox of your own";

  inputs = {
    nixpkgs.url = "git+ssh://gitea/mirrors/nixpkgs?shallow=1&ref=nixos-unstable";
    flake-utils.url = "git+ssh://gitea/mirrors/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        claude = pkgs.callPackage ./claude.nix { };
        codex = pkgs.callPackage ./codex.nix { };
      in
      {
        packages = {
          default = claude;
          inherit claude codex;
        };

        apps = {
          update-claude = {
            type = "app";
            program = "${pkgs.writeShellScript "update-claude" ''
              export PATH=${pkgs.lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.nix pkgs.gnused ]}:$PATH
              exec ${./update-claude.sh}
            ''}";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            claude
            codex
          ];
          
          shellHook = ''
            echo "Claude Code and Codex"
          '';
        };
      });
}
