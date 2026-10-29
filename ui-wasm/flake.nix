# The Qt-for-WebAssembly dev shell, in its own flake.
#
# It lives here rather than in the repository root flake because its Qt comes
# from `path:/home/pde/Projects/qt6-wasm`, which is a local checkout. A flake
# resolves every input eagerly, so that one path made the ROOT flake
# unusable to anybody else: `inputs.nixdash.url = "github:..."` failed on a
# machine without that directory, and so did `nix run github:...`, even though
# nothing in packages.engine, packages.ui or the home-manager module touches
# it. The root flake now has only github: inputs and installs anywhere;
# building the wasm UI is still author-only, which it always was.
#
#   nix develop ./ui-wasm --command bash ui-wasm/build.sh
{
  description = "nixdash browser UI - Qt 6 for WebAssembly toolchain";

  inputs = {
    # Same revision as the root flake, so the host Qt matches.
    nixpkgs.url = "github:NixOS/nixpkgs/7fc6f2c20af0";

    # Qt 6.11.2 cross-compiled for WebAssembly, plus the emsdk shim and a
    # Rust toolchain carrying wasm32-unknown-emscripten std.
    qt6-wasm = {
      url = "path:/home/pde/Projects/qt6-wasm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, qt6-wasm }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default =

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
    };
}
