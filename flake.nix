{
  description = "Zig Async Threading POC";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
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
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default =
          let
            packages = with pkgs; [ zig ];
          in
          pkgs.mkShell {
            buildInputs = packages;
            shellHook = '''';
          };
      }
    );
}
