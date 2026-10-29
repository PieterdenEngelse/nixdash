# The engine, cross-compiled to Windows.
#
# Half of the MSI payload. The other half - the Qt UI - cannot be built here:
# pkgsCross.mingwW64.qt6.qtdeclarative is marked unsupported and does not
# evaluate, so the UI needs a Windows runner with an official Qt. See
# packaging/wix/README.md.
#
# The engine itself needs nothing from the platform at compile time: it is
# pure Rust with no std::os::unix anywhere, which is why this works at all.
# What it needs from the platform at RUNTIME it does not get, and that is the
# honest result rather than a bug - see the note on degradation below.
#
# Driven by a CROSS stdenv rather than by setting CARGO_BUILD_TARGET on a
# native one. That was the first attempt and it silently produced an ELF
# binary named nixdash-engine: buildRustPackage sets CARGO_BUILD_TARGET itself
# from stdenv.hostPlatform, so the variable set here was overwritten, and the
# install phase then found the host artifact and installed it. Nothing failed.
# Checking the magic bytes is the only reason it was caught - 7f 45, not 4d 5a.
#
# With mingwW64's own makeRustPlatform, the target triple and the linker are
# both derived from hostPlatform and cannot disagree with each other.
{
  lib,
  mingwPkgs,
  rustWindows,
}:

let
  # cargo and rustc run on the builder; only rust-std is per-target. Taking
  # makeRustPlatform from the cross set is what sets hostPlatform to Windows.
  rustPlatform = mingwPkgs.makeRustPlatform {
    cargo = rustWindows;
    rustc = rustWindows;
  };
in
rustPlatform.buildRustPackage {
  pname = "nixdash-engine-windows";
  version = (lib.importTOML ../Cargo.toml).workspace.package.version;

  # Same filter as nix/engine.nix, and for the same reason: target/ holds
  # gigabytes.
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

  # The tests are run by nix/engine.nix on the host. Here they would have to
  # be run under Wine to mean anything, and a test suite that silently does
  # not run is worse than one that is openly somewhere else.
  doCheck = false;

  meta = {
    description = "nixdash engine for Windows (NixOS panels report 'could not look')";
    mainProgram = "nixdash-engine.exe";

    platforms = lib.platforms.windows;
  };
}
