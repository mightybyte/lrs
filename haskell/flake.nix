{
  description = "lrs - longest repeated substring finder";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ] (system:
    let
      overlays = [ haskellNix.overlay
        (final: prev: {
          lrs-project =
            final.haskell-nix.cabalProject' {
              src = ./.;
              compiler-nix-name = "ghc9121";
              modules = [
                  {
                      enableProfiling = true;
                      enableLibraryProfiling = true;
                  }
              ];
              shell.tools = {
                cabal = {};
                ghcid = {};
                hlint = {};
              };
            };
        })
      ];
      pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
      flake = pkgs.lrs-project.flake {};
    in flake // {
      packages.default = flake.packages."lrs:exe:lrs";
      inherit pkgs;
    });
}
