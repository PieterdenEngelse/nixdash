# The engine package, shared by flake.nix and the home-manager module so there
# is exactly one definition of how it is built.
#
# Deliberately Qt-free: the engine is a headless HTTP service. Only the UIs
# need Qt, and keeping that out of here means the home-manager module can
# install the service without dragging in a Qt closure.
{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nixdash-engine";
  version = (lib.importTOML ../Cargo.toml).workspace.package.version;

  # Filter the source rather than passing the directory wholesale: target/
  # holds gigabytes of build output, and this is not a git repo so nothing
  # else excludes it.
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
    "nixdash-engine"
  ];
  cargoTestFlags = [
    "-p"
    "nixdash-engine"
  ];

  # The failed-units collector shells out to systemctl, resolved from PATH at
  # runtime rather than pinned: the engine must report on the systemd actually
  # running the machine, not one from its own closure.

  meta = {
    description = "NixOS config and monitoring engine (loopback only)";
    mainProgram = "nixdash-engine";
    platforms = lib.platforms.linux;
  };
}
