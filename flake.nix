{
  description = "nixdash - NixOS config & monitoring, Rust engine + Qt/QML UIs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/7fc6f2c20af0";

    # Qt 6.11.2 cross-compiled for WebAssembly, plus the emsdk shim and a Rust
    # toolchain carrying wasm32-unknown-emscripten std. Only the wasm UI needs
    # it; the engine and desktop UI do not.
    qt6-wasm = {
      url = "path:/home/pde/Projects/qt6-wasm";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixpkgs' rustc ships std for the host only, so cross-compiling the
    # engine to Windows fails with "can't find crate for `std`" - the same
    # wall qt6-wasm hit for wasm32-unknown-emscripten, and fenix is the same
    # answer: upstream Rust's per-target std, inside Nix, with no rustup.
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, qt6-wasm, fenix }:
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

      # rustc and cargo plus the Windows target's std. cargo runs on the host,
      # so only rust-std is per-target.
      rustWindows = fenix.packages.${system}.combine (
        with fenix.packages.${system};
        [
          stable.rustc
          stable.cargo
          targets."x86_64-pc-windows-gnu".stable.rust-std
        ]
      );

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

        # `nix build .#engine-windows` - nixdash-engine.exe. The UI half of the
        # MSI is not buildable here; see nix/windows-engine.nix.
        engine-windows = pkgs.callPackage ./nix/windows-engine.nix {
          inherit rustWindows;
          mingwPkgs = pkgs.pkgsCross.mingwW64;
        };

        default = engine;
      };

      devShells.${system} = {
        # Qt-for-wasm shell: `nix develop .#wasm`, then ui-wasm/build.sh
        wasm =
          let sdk = qt6-wasm.packages.${system}; in
          pkgs.mkShell {
            packages = [ sdk.rustToolchain ] ++ (with pkgs; [
              cmake ninja python3 git curl jq
            ]);

            EMSDK = sdk.emsdk;
            QT_HOST_PATH = sdk.hostQt;
            QT_WASM_TOOLCHAIN = "${sdk.qtbase-wasm}/lib/cmake/Qt6/qt.toolchain.cmake";

            # qt.toolchain.cmake RESETS CMAKE_PREFIX_PATH to qtbase's own
            # prefix, so -DCMAKE_PREFIX_PATH at the merged prefix is silently
            # dropped ("Could NOT find Qt6Qml"). This variable survives it.
            QT_ADDITIONAL_PACKAGES_PREFIX_PATH = sdk.qt6-wasm;

            # Must be the WASM qmake, never the host one.
            CXXQT_QMAKE = "${sdk.qt6-wasm}/bin/qmake";

            # rcc runs from the HOST Qt, which has zstd; the wasm Qt Core does
            # not, so a zstd-compressed .qrc fails to link with
            #   undefined symbol: qResourceFeatureZstd()
            # rcc only reaches for zstd once the payload is worth compressing,
            # so this stays hidden until a project has more than a file or two
            # of QML. Colon-separated; passed through to rcc.
            CXX_QT_AUTORCC_OPTIONS = "--no-zstd";

            shellHook = ''
              # emcc needs a writable cache. Copy from the REAL emscripten with
              # -L: the emsdk shim is a symlink farm into the store, and a copy
              # of it keeps read-only symlinks ("Could NOT find Threads").
              export EM_CACHE="$(mktemp -d)/emcache"
              cp -rL ${sdk.emscripten}/share/emscripten/cache "$EM_CACHE"
              chmod -R u+w "$EM_CACHE"
              export PATH="${sdk.emsdk}/share/emscripten:$PATH"
              echo "nixdash wasm UI  |  $(rustc --version)"
              echo "  ./ui-wasm/build.sh   then   ./ui-wasm/serve.sh"
            '';
          };

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
