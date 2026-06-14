{
  description = "Jafar — JFR parser and the jfr-mcp MCP server, built fully locally as a Nix derivation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        jfr-mcp = pkgs.callPackage ./nix/jfr-mcp.nix { };
      in
      {
        packages = {
          inherit jfr-mcp;
          default = jfr-mcp;
        };

        apps = {
          jfr-mcp = {
            type = "app";
            program = "${jfr-mcp}/bin/jfr-mcp";
          };
          default = self.apps.${system}.jfr-mcp;

          # Regenerate nix/deps.json after changing module dependencies:
          #   nix run .#update-deps
          # Wrapped in a script (rather than calling the updater directly)
          # because the updater must write the lockfile back into the working
          # tree, which requires referencing the package at its real on-disk
          # path. See nix/update-deps.sh.
          update-deps = {
            type = "app";
            program = "${pkgs.writeShellScript "jfr-mcp-update-deps" ''
              exec ${pkgs.bash}/bin/bash ${./nix/update-deps.sh} "$@"
            ''}";
          };
        };
      }
    );
}
