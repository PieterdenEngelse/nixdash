{
  description = "nixdash - NixOS config & monitoring, Rust engine + Qt/QML UIs";

  # Every input here is a github: URL, deliberately. A flake resolves all of
  # its inputs eagerly, so a single `path:` input to a local checkout makes
  # the whole flake unusable to anyone else - `inputs.nixdash.url =
  # "github:..."` and `nix run github:...` both fail on a machine that does
  # not have that directory, however little of the flake depends on it. The
  # Qt-for-WebAssembly shell needs exactly such a checkout, so it lives in
  # ui-wasm/flake.nix instead: `nix develop ./ui-wasm`.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/7fc6f2c20af0";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # cxx-qt interrogates a single qmake for headers, libs AND host tools
      # (moc, rcc, qmltyperegistrar, qmlcachegen). On NixOS those span separate
      # store paths, so it needs one merged prefix. qt6.env is what provides
      # it - a plain symlinkJoin does not, because nixpkgs' qmake has its
      # prefix baked in. See ~/docs/qt.md, Part 1.
      qtEnv = pkgs.qt6.env "nixdash-qt-env" (with pkgs.qt6; [
        qtdeclarative
        qtsvg
        qtshadertools
      ]);

      qtRuntime = {
        QT_PLUGIN_PATH = "${qtEnv}/${pkgs.qt6.qtbase.qtPluginPrefix}";
        QML2_IMPORT_PATH = "${qtEnv}/${pkgs.qt6.qtbase.qtQmlPrefix}";
      };

      # Optional dev shell additions, toggled from nixdash's Config page.
      # That file is GENERATED - nixdash rewrites it whole. This flake is
      # hand-written and the app never touches it, which is what keeps the
      # comments above intact.
      devshellExtras = import ./nix/devshell-extras.nix { inherit pkgs; };
    in
    {
      packages.${system} = rec {
        # Single definition, shared with the home-manager module in
        # nix/hm-module.nix so the service and `nix build` cannot drift.
        engine = pkgs.callPackage ./nix/engine.nix { };

        # Shared with the home-manager module; see nix/ui.nix.
        ui = pkgs.callPackage ./nix/ui.nix { };

        default = engine;
      };

      devShells.${system} = {
        # Optional additions nixdash can toggle from its Config page. The
        # file is generated and rewritten whole by the app; this flake is
        # hand-written and the app never edits it, which is the only way its
        # comments survive. Re-enter the shell for a change to take effect.
        default = pkgs.mkShell ({
        packages = (with pkgs; [
          rustc
          cargo
          rustfmt
          clippy
          rust-analyzer
          qtEnv
          pkg-config
          curl
          jq
          # The Justfile is the one definition of every build command; see
          # CLAUDE.md. From outside this shell: nix develop --command just <recipe>
          just
        ]) ++ devshellExtras.packages;

        # Qt6Gui/Qt6OpenGL .prl files reference -lGLX and -lOpenGL, which live
        # in libglvnd. buildInputs (not packages) so the cc wrapper picks up
        # its -L via NIX_LDFLAGS.
        buildInputs = [ pkgs.libglvnd ];

        # Silences the wall of "_FORTIFY_SOURCE requires compiling with
        # optimization (-O)" from every generated cxx-qt translation unit.
        # The cc wrapper puts -O2 -D_FORTIFY_SOURCE=3 around each compile;
        # a plain `cargo build` then passes -O0, which wins because it comes
        # later, and glibc's #warning fires once per file. Fortify does
        # nothing at -O0 anyway, so turning it off in the dev shell loses no
        # checking. BOTH names are needed: fortify3 re-implies fortify and
        # then overrides it, so dropping only `fortify` changes nothing -
        # verified by the -D_FORTIFY_SOURCE define surviving. This is the dev
        # shell only; the packaged build is a separate derivation with its own
        # hardening, and it builds optimised where fortify works.
        hardeningDisable = [ "fortify" "fortify3" ];

        QMAKE = "${qtEnv}/bin/qmake";
        RUST_LOG = "nixdash_engine=debug,tower_http=warn";

        # Qt logging does not reach stderr on this system, so a QML error
        # produces a running process, no window, and ZERO output. That has
        # cost hours. Make failures visible by default in the dev shell.
        QT_FORCE_STDERR_LOGGING = "1";
        # Extras last, so a generated RUST_SRC_PATH lands - but this flake
        # sets nothing it would override, and `//` is Nix's update operator
        # here, not a comment.
        } // qtRuntime // devshellExtras.env);
      };

      # Importable from a channel-based Home Manager by path, so no flake
      # plumbing is needed on the consumer side:
      #   imports = [ /home/pde/Projects/nixdash/nix/hm-module.nix ];
      homeManagerModules.default = ./nix/hm-module.nix;

      apps.${system} = {
        default = {
          type = "app";
          program = "${self.packages.${system}.engine}/bin/nixdash-engine";
          meta.description = "nixdash engine";
        };
        ui = {
          type = "app";
          program = "${self.packages.${system}.ui}/bin/nixdash-ui";
          meta.description = "nixdash desktop UI";
        };
      };
    };
}
