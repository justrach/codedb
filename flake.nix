{
  description = "codedb - code intelligence server for AI agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # build.zig.zon pins a Zig nightly (minimum_zig_version). nixpkgs only
    # carries tagged releases, so the toolchain comes from the overlay's
    # master-<date> snapshot that matches that exact nightly.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig-overlay }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

      # Snapshot providing 0.17.0-dev.813+2153f8143 — keep in step with
      # `.minimum_zig_version` in build.zig.zon.
      zigSnapshot = "master-2026-06-07";
      zigFor = system: zig-overlay.packages.${system}.${zigSnapshot};

      # Single source of truth for the version: build.zig.zon.
      version =
        let
          lines = lib.splitString "\n" (builtins.readFile ./build.zig.zon);
          pattern = "[[:space:]]*\\.version = \"([^\"]+)\",?[[:space:]]*";
          matches = builtins.filter (m: m != null) (map (l: builtins.match pattern l) lines);
        in
        if matches == [ ] then "0.0.0" else builtins.head (builtins.head matches);

      zigFlags = [
        "-Doptimize=ReleaseFast"
        "-Dcpu=baseline"
      ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          zig = zigFor system;
        in
        rec {
          default = codedb;
          codedb = pkgs.stdenv.mkDerivation {
            pname = "codedb";
            inherit version;

            src = lib.cleanSourceWith {
              src = ./.;
              filter = path: type:
                let
                  name = builtins.baseNameOf path;
                in
                !(lib.elem name [
                  ".git"
                  ".direnv"
                  ".zig-cache"
                  "zig-out"
                  "result"
                  "codedb.snapshot"
                ]);
            };

            # zig links libc dynamically and bakes in the host's default ELF
            # interpreter (/lib64/ld-linux-*), which does not exist on NixOS —
            # autoPatchelfHook rewrites it to the glibc in buildInputs.
            nativeBuildInputs = [ zig ]
              ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
            buildInputs = lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.libc;
            strictDeps = true;
            dontConfigure = true;
            dontBuild = true;

            # All Zig dependencies are vendored as path deps in build.zig.zon,
            # so the build needs no network access — only writable caches.
            preInstall = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
            '';

            installPhase = ''
              runHook preInstall
              zig build install ${lib.escapeShellArgs zigFlags} --prefix "$out" --color off
              runHook postInstall
            '';

            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              "$out/bin/codedb" --version
              test -f "$out/share/codedb/install-hooks.sh"
              runHook postInstallCheck
            '';

            meta = {
              description = "Code intelligence server for AI agents";
              homepage = "https://github.com/justrach/codedb";
              license = lib.licenses.bsd3;
              mainProgram = "codedb";
              platforms = lib.platforms.linux ++ lib.platforms.darwin;
            };
          };
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${system}.default;
          meta.description = "Run codedb";
        };
      });

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [ (zigFor system) pkgs.jq pkgs.python3 ];
          };
        });
    };
}
