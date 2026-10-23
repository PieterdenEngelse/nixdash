# Home Manager module for nixdash.
#
# Installs the engine and runs it as a *user* service. Deliberately a user
# unit, not a system one: the engine holds no privilege and reports only what
# you can already read yourself. If this ever needs root, the design has gone
# wrong - see the "no escalation" rule in the README.
#
# Usage (channel-based Home Manager, as configured on this machine):
#
#   # ~/.config/home-manager/modules/nixdash.nix
#   { ... }: {
#     imports = [ /home/pde/Projects/nixdash/nix/hm-module.nix ];
#     services.nixdash.enable = true;
#   }
#
# then add it to the imports list in home.nix.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nixdash;

  # The menu entry and the panel launcher run THIS, not the installed binary
  # directly, so the icon starts whichever build is newer.
  #
  # Without it the icon runs the build from the last `home-manager switch`
  # while a freshly compiled one sits in the tree, the two windows look
  # identical, and half an afternoon goes into testing a three-hour-old
  # binary. Store paths all carry the same epoch mtime, so "newer" compares
  # the local binary against the generation symlink - the moment the installed
  # one was switched in.
  # A package rather than a bare store path, so it lands in the profile at
  # bin/nixdash-ui-launch and the Exec line below can name something STABLE.
  #
  # Xfce copies a .desktop file into ~/.config/xfce4/panel/launcher-N/ when
  # you drag it onto the panel, freezing whatever Exec it held at that moment.
  # A store path frozen there pins one build for ever: the panel kept starting
  # a six-hour-old nixdash across several switches, so every "restart it and
  # try again" handed back the same stale window while the tree moved on. The
  # profile directory follows the generation, so the frozen copy stays right.
  launcherPkg = pkgs.writeShellScriptBin "nixdash-ui-launch" ''
    set -u

    installed=${lib.getExe cfg.ui.package}
    dev=${lib.escapeShellArg (toString cfg.ui.devBuild)}
    gen="''${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"

    if [ -n "$dev" ] && [ -x "$dev" ]        && [ "$(stat -c %Y "$dev" 2>/dev/null || echo 0)"             -gt "$(stat -c %Y "$gen" 2>/dev/null || echo 0)" ]; then
      # A cargo build is not wrapped, so it needs the paths wrapQtAppsHook
      # would have given it. Without these Qt finds no platform plugin and
      # the window never appears.
      export QT_PLUGIN_PATH="${cfg.ui.package.qtEnv}/${pkgs.qt6.qtbase.qtPluginPrefix}"
      export QML2_IMPORT_PATH="${cfg.ui.package.qtEnv}/${pkgs.qt6.qtbase.qtQmlPrefix}"
      export NIXPKGS_QT6_QML_IMPORT_PATH="$QML2_IMPORT_PATH"
      exec "$dev" "$@"
    fi

    exec "$installed" "$@"
  '';

  # Where launcherPkg ends up once installed. Stable across generations,
  # which is the whole point - see the comment on launcherPkg.
  launcherPath = "${config.home.profileDirectory}/bin/nixdash-ui-launch";

  # Built once and used twice: as the menu entry and as the autostart file.
  # Referencing the generated entry by its runtime path instead would not
  # exist at evaluation time.
  desktopItem = pkgs.makeDesktopItem {
    name = "nixdash";
    desktopName = "nixdash";
    comment = "NixOS config and monitoring";
    # The UI reads NIXDASH_PORT to find the engine, so the entry has to carry
    # whatever port the service was configured with.
    # The profile path, not the package's own store path. A store path here
    # is correct
    # only until the next switch, and anything that copies this entry keeps
    # it long after that.
    exec = "env NIXDASH_PORT=${toString cfg.port} ${launcherPath}";
    # Themed name, resolved from hicolor below - not an absolute path. The
    # icon is scalable, so the theme lookup is what lets a 24px panel and a
    # 48px menu each get a crisp render from the one SVG.
    icon = "nixdash";
    terminal = false;
    categories = [
      "System"
      "Monitor"
    ];
  };
in
{
  options.services.nixdash = {
    enable = lib.mkEnableOption "the nixdash monitoring engine";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./engine.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./engine.nix { }";
      description = "The nixdash engine package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = ''
        Port on 127.0.0.1 to listen on.

        Only the port is configurable, never the address: the engine has no
        authentication and no TLS, so it binds loopback unconditionally.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "nixdash_engine=info,tower_http=warn";
      example = "nixdash_engine=debug,tower_http=debug";
      description = "Value of RUST_LOG for the service.";
    };

    # The browser UI's server, supervised rather than started by hand.
    #
    # Off by default: it serves a directory in the development tree, so it is
    # for someone working on this project, not for running it.
    #
    # It exists because an unsupervised server outlived what it was serving.
    # One started from a terminal was still holding :8099 a full day later,
    # with its working directory the build/ work area, quietly serving a
    # half-written bundle while a freshly published one sat beside it - and
    # the symptom was a WebAssembly instantiation error that reads as a
    # broken build. A unit gives the thing one owner: `systemctl --user
    # restart` has a single meaning, a second start is refused instead of
    # failing on bind(2), `status` says what it is serving, and it does not
    # outlive the session.
    browser = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run the browser UI's static server as a user service.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8099;
        description = ''
          Port on 127.0.0.1 for the browser UI.

          Loopback only, like the engine, and for the same reason: there is
          nothing here to authenticate against.
        '';
      };

      tree = lib.mkOption {
        type = lib.types.str;
        default = "${toString ../.}/ui-wasm/current";
        defaultText = lib.literalExpression ''"\''${toString ../.}/ui-wasm/current"'';
        description = ''
          Directory to serve.

          The default is the symlink `ui-wasm/build.sh` flips on a successful
          build, never `ui-wasm/build` itself: that one holds a mixture of two
          builds during a link and after an interrupted one, and serving it is
          what made that mixture the browser's problem.
        '';
      };
    };

    ui = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the desktop UI and a menu entry for it.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./ui.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./ui.nix { }";
        description = "The nixdash desktop UI package.";
      };

      devBuild = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "${toString ../.}/target/debug/nixdash-ui";
        defaultText = lib.literalExpression ''"\''${toString ../.}/target/debug/nixdash-ui"'';
        description = ''
          Path to a local `cargo build -p nixdash-ui` binary. When it is newer
          than the installed generation, the menu entry and the panel launcher
          run it instead of the installed one - so the icon always starts the
          most recent build rather than the last one switched in. Set to null
          to always run the installed binary.
        '';
      };

      autostart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open the UI at login. Off by default: the engine collects with no UI running, so this is about whether you want a window every boot, not whether monitoring happens.";
      };
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start at login. Turn this off to keep the unit installed but
        hand-started with `systemctl --user start nixdash-engine`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # A dashboard you have to remember to launch is a dashboard you will not
    # look at. Installing the desktop item puts nixdash in the application
    # menu; autostart additionally opens it at login.
    home.packages =
      [ cfg.package ]
      ++ lib.optionals cfg.ui.enable [
        cfg.ui.package
        desktopItem
        # Installed so that launcherPath above resolves, and so the launcher
        # can be run by name from a shell like any other command.
        launcherPkg
      ];

    # The icon, installed into the user's hicolor theme so `Icon=nixdash`
    # resolves from the menu entry, the panel launcher and the window manager
    # alike. scalable/ rather than a fixed size: one SVG serves every size,
    # and no icon cache needs regenerating for scalable entries.
    home.file.".local/share/icons/hicolor/scalable/apps/nixdash.svg" =
      lib.mkIf cfg.ui.enable { source = ../assets/nixdash.svg; };

    # XDG autostart rather than a systemd graphical-session unit: Xfce honours
    # ~/.config/autostart reliably, and its graphical-session.target wiring is
    # less dependable.
    xdg.configFile."autostart/nixdash.desktop" = lib.mkIf (cfg.ui.enable && cfg.ui.autostart) {
      source = "${desktopItem}/share/applications/nixdash.desktop";
    };

    systemd.user.services.nixdash-engine = {
      Unit = {
        Description = "nixdash engine (NixOS monitoring, loopback only)";
        Documentation = "file://${../README.md}";
        # Without this the service can start before the user session has a
        # D-Bus socket, and the user-scope half of the failed-units collector
        # reports "unavailable" for the first few samples.
        After = [ "graphical-session-pre.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = lib.getExe cfg.package;
        Environment = [
          "NIXDASH_PORT=${toString cfg.port}"
          "RUST_LOG=${cfg.logLevel}"
        ];
        Restart = "on-failure";
        RestartSec = "5s";

        # This service used to be tightly sandboxed, on the grounds that the
        # engine needed no privilege at all. It now runs actions via pkexec,
        # and that changes what is possible here.
        #
        # pkexec is setuid and execs the target program *in place* - same
        # cgroup, same namespaces, same mount view. Whatever restricts this
        # unit restricts `nixos-rebuild switch` too. So the old settings did
        # not merely fail to help, they broke the feature in ways that would
        # have been miserable to diagnose:
        #
        #   NoNewPrivileges       setuid cannot take effect; pkexec just fails
        #   ProtectSystem=strict  /nix/store read-only - no build can finish
        #   RestrictNamespaces    removes the namespaces Nix sandboxes builds in
        #   ProtectKernel*        activation sets sysctls; systemd writes cgroups
        #   ProtectHome           nix as root wants a writable /root
        #   PrivateTmp            builds use /tmp, and would not see the real one
        #   MemoryDenyWriteExecute  gratuitous risk for anything with a JIT
        #
        # Removing them is the honest price of the Run button, not an
        # oversight.
        #
        # Nothing is left, and that is not laziness either. The two that looked
        # free - LockPersonality and SystemCallArchitectures - are implemented
        # with **seccomp**, and systemd cannot install a seccomp filter in an
        # unprivileged user unit without also setting NoNewPrivileges. So they
        # silently re-enable the one setting that makes setuid a no-op:
        #
        #   systemctl --user show nixdash-engine -p NoNewPrivileges  ->  no
        #   grep NoNewPrivs /proc/$(pidof nixdash-engine)/status     ->  1
        #
        # The unit claims one thing and the kernel reports another, and pkexec
        # fails with "pkexec must be setuid root" - which sounds like a broken
        # polkit install, not a sandbox setting you chose. NoNewPrivs is also
        # inherited and can never be cleared, so a stale process keeps it
        # across a config change until it is actually restarted.
        #
        # If you add ANY seccomp-based option here (SystemCallFilter,
        # MemoryDenyWriteExecute, RestrictRealtime, RestrictSUIDSGID,
        # LockPersonality, SystemCallArchitectures), privileged actions stop
        # working and the error will not point here.
      };

      Install = lib.mkIf cfg.autoStart {
        WantedBy = [ "default.target" ];
      };
    };

    systemd.user.services.nixdash-serve = lib.mkIf cfg.browser.enable {
      Unit = {
        Description = "nixdash browser UI server (loopback only)";
        After = [ "graphical-session-pre.target" ];
      };

      Service = {
        Type = "simple";
        # The script from the working tree, not a store copy: this serves a
        # directory in that tree and is edited alongside it, so a store copy
        # would be a second version to keep in step.
        #
        # serve.py directly rather than serve.sh: the wrapper's job is to pick
        # a tree and tell you who holds the port, and systemd does both of
        # those better - the tree is configuration here, and a second start is
        # refused by the unit.
        # The tree is an ARGUMENT, not WorkingDirectory. systemd resolves
        # WorkingDirectory once at start, so with `current` being a symlink
        # the server was pinned to whichever release was current then and
        # served it for ever - verified: cwd was releases/20261022-073615
        # while current had moved on. Passed as a path, every request
        # resolves the symlink again.
        ExecStart = "${pkgs.python3}/bin/python3 ${toString ../.}/ui-wasm/serve.py ${toString cfg.browser.port} ${cfg.browser.tree} --quiet";
        Restart = "on-failure";
        RestartSec = "5s";
      };

      Install = {
        # Dies with the session, which is the point: the server that caused
        # the trouble had outlived the day it was started in.
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
