# The desktop UI package, shared by flake.nix and the home-manager module.
#
# Unlike nix/engine.nix this drags in Qt, which is why the two are separate:
# the service can be installed without a Qt closure.
{
  lib,
  rustPlatform,
  qt6,
  libglvnd,
}:

let
  # cxx-qt interrogates ONE qmake for headers, libs and host tools (moc, rcc,
  # qmltyperegistrar, qmlcachegen). On NixOS those span separate store paths,
  # so it needs a merged prefix. qt6.env provides one; a plain symlinkJoin does
  # not, because nixpkgs' qmake has its prefix baked in. See ~/docs/qt.md.
  qtEnv = qt6.env "nixdash-qt-env" (
    with qt6;
    [
      qtdeclarative
      qtsvg
      qtshadertools
    ]
  );
in
rustPlatform.buildRustPackage {
  pname = "nixdash-ui";
  version = "0.1.1";

  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      !(builtins.elem base [
        "target"
        "build"
        ".direnv"
      ])
      && !(lib.hasPrefix "result" base);
  };

  cargoLock.lockFile = ../Cargo.lock;
  cargoBuildFlags = [
    "-p"
    "nixdash-ui"
  ];
  # The UI has no tests of its own; the engine's are run by nix/engine.nix.
  doCheck = false;

  nativeBuildInputs = [
    qtEnv
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtsvg
    # Qt6Gui/Qt6OpenGL .prl files reference -lGLX and -lOpenGL. buildInputs, so
    # the cc wrapper picks up its -L via NIX_LDFLAGS.
    libglvnd
  ];

  # qtbase-setup-hook.sh unconditionally exports QMAKE=${qtbase}/bin/qmake,
  # pointing cxx-qt back at the unmerged prefix. Setup hooks run before the
  # build phases, so re-export here to win.
  preBuild = ''
    export QMAKE=${qtEnv}/bin/qmake
  '';

  # Exposed so the home-manager module can hand an unwrapped local build the
  # same plugin and QML import paths wrapQtAppsHook bakes into this one.
  # Defining the env a second time there would be a third copy of the comment
  # above, and a chance for the two to drift.
  passthru = {
    inherit qtEnv;
  };

  meta = {
    description = "nixdash desktop UI";
    mainProgram = "nixdash-ui";
    platforms = lib.platforms.linux;
  };
}
