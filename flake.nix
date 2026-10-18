{
  description = "SwiftGrep (sg): a ripgrep-compatible search tool for macOS, tuned for APFS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # macOS 27 runs only on Apple silicon.
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = rec {
        swift-toolchain = pkgs.callPackage ./nix/swift-toolchain.nix { };
        sg = pkgs.callPackage ./nix/sg.nix { inherit swift-toolchain; };
        default = sg;
      };
    };
}
