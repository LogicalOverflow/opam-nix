{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    opam2json.url = "github:tweag/opam2json";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    # Used for examples/tests and as a default repository
    opam-repository = {
      url = "github:ocaml/opam-repository";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, flake-utils, opam2json, opam-repository, ... }@inputs:
    {
      aux = import ./src/lib.nix nixpkgs.lib;
      templates.simple = {
        description = "Build a package from opam-repository";
        path = ./templates/simple;
      };
      templates.local = {
        description = "Build an opam package from a local directory";
        path = ./templates/local;
      };
      defaultTemplate = self.templates.local;

      overlays = {
        ocaml-overlay = import ./src/overlays/ocaml.nix;
        ocaml-static-overlay = import ./src/overlays/ocaml-static.nix;
        default = final: prev: {
          opam = prev.opam.overrideAttrs (oa: {
            patches = oa.patches or [ ] ++ [ ./patches/opam.patch ];
          });
          lndir-level = prev.xorg.lndir.overrideAttrs (oa: {
            patches = oa.patches or [ ] ++ [ ./patches/lndir-level.patch ];
          });
        };
      };
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system}.extend
          (nixpkgs.lib.composeManyExtensions [
            opam2json.overlay
            self.overlays.default
          ]);
        opam-nix = import ./src/opam.nix { inherit pkgs opam-repository; };
      in rec {
        lib = opam-nix;
        checks = packages
          // (pkgs.callPackage ./examples/readme { inherit opam-nix; });

        packages = let
          examples = rec {
            _0install = (import ./examples/0install/flake.nix).outputs {
              self = _0install;
              opam-nix = inputs.self;
              inherit (inputs) flake-utils;
            };
            frama-c = (import ./examples/frama-c/flake.nix).outputs {
              self = frama-c;
              opam-nix = inputs.self;
              inherit (inputs) flake-utils;
            };
            opam-ed = (import ./examples/opam-ed/flake.nix).outputs {
              self = opam-ed;
              opam-nix = inputs.self;
              inherit (inputs) flake-utils;
            };
            opam2json = (import ./examples/opam2json/flake.nix).outputs {
              self = opam2json;
              opam-nix = inputs.self;
              inherit (inputs) opam2json flake-utils;
            };
            ocaml-lsp = (import ./examples/ocaml-lsp/flake.nix).outputs {
              self = ocaml-lsp;
              opam-nix = inputs.self;
              inherit (inputs) nixpkgs flake-utils;
            };
            opam2json-static =
              (import ./examples/opam2json-static/flake.nix).outputs {
                self = opam2json-static;
                opam-nix = inputs.self;
                inherit (inputs) opam2json flake-utils;
              };
            tezos = (import ./examples/tezos/flake.nix).outputs {
              self = tezos;
              opam-nix = inputs.self;
              inherit (inputs) flake-utils;
            };
            materialized-opam-ed =
              (import ./examples/materialized-opam-ed/flake.nix).outputs {
                self = materialized-opam-ed;
                opam-nix = inputs.self;
                inherit (inputs) flake-utils;
              };
          };
        in {
          opam-nix-gen = pkgs.substituteAll {
            name = "opam-nix-gen";
            src = ./scripts/opam-nix-gen.in;
            dir = "bin";
            isExecutable = true;
            inherit (pkgs) runtimeShell coreutils nix;
            opamNix = "${self}";
          };
          opam-nix-regen = pkgs.substituteAll {
            name = "opam-nix-regen";
            src = ./scripts/opam-nix-regen.in;
            dir = "bin";
            isExecutable = true;
            inherit (pkgs) runtimeShell jq;
            opamNixGen =
              "${self.packages.${system}.opam-nix-gen}/bin/opam-nix-gen";
          };
        } // builtins.mapAttrs (_: e: e.defaultPackage.${system}) examples;
      });
}
