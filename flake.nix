{
  description = "Monitor Settings: display arrangement and DDC/CI monitor controls, as a Quickshell app";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        monitor-settings = pkgs.callPackage ./nix/package.nix { };
        default = monitor-settings;
      });

      overlays.default = final: _prev: {
        monitor-settings = final.callPackage ./nix/package.nix { };
      };

      homeManagerModules = rec {
        monitor-settings = import ./nix/hm-module.nix self;
        default = monitor-settings;
      };

      # The parsing/layout tests (monitor-settings/app/tests/run.mjs).
      checks = forAllSystems (pkgs: {
        tests = pkgs.runCommand "monitor-settings-tests" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
          node ${self}/monitor-settings/app/tests/run.mjs
          touch $out
        '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
