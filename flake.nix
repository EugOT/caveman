{
  description = "caveman — test & coverage toolchain (kcov, zig, JS/Py mutation tools)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs
          [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]
          (system: f (import nixpkgs { inherit system; }));
    in
    {
      # `nix develop` — the reproducible test/coverage/mutation toolchain.
      #
      # Provides the pieces that aren't on a bare machine:
      #   - kcov        : line+branch coverage for the Zig test binaries
      #                   (used by `zig build test -Dtest-coverage`)
      #   - zig         : the compiler (0.16 dev series; pin via overlay on CI if a
      #                   specific dev build is required — nixpkgs zig may lag)
      #   - bun         : JS coverage (c8) + mutation (Stryker) via bunx
      #   - python3 + coveragepy : Python coverage; cosmic-ray installed per-pixi-env
      #
      # The self-hosted CI runners consume this same devShell so the local and CI
      # toolchains are byte-identical. JS/Py *mutation* tools (Stryker, cosmic-ray)
      # are run through bunx/pixi per repo policy, not pinned here.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.kcov
            pkgs.zig
            pkgs.bun
            (pkgs.python3.withPackages (ps: [ ps.coverage ]))
          ];
          shellHook = ''
            echo "caveman test toolchain: kcov $(kcov --version 2>/dev/null | head -1), zig $(zig version 2>/dev/null), bun $(bun --version 2>/dev/null)"
            echo "coverage:  (cd zig && zig build test -Dtool=caveman -Dtest-coverage)  →  zig/zig-out/coverage/"
          '';
        };
      });

      # `nix flake check` smoke target.
      checks = forAllSystems (pkgs: {
        toolchain-present = pkgs.runCommand "toolchain-present" { } ''
          ${pkgs.kcov}/bin/kcov --version >/dev/null
          touch $out
        '';
      });
    };
}
