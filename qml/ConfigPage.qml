import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// How this machine is set up, and what to change.
//
// NOT a settings form. This machine is configured declaratively; a form with
// input fields would either write somewhere Nix later overwrites, or fight
// Nix outright. Either way it would lie about where configuration lives.
//
// So each subject answers three questions - what is in effect, where it is
// declared, and what to change it to - and the third is a snippet you copy.
//
// The *rows* stay read-only for that reason. The actions panel at the bottom
// can run shell actions, but never the Nix snippets: those have to go into a
// file you own, and no button can decide which file that is.
Item {
    id: root

    Style { id: style }

    property var panels: []
    property var actions: []
    property string apiBase: ""

    // A run changes exactly the state these sections read, so the shell
    // re-polls afterwards.
    signal ranAction()

    function panel(id) {
        var m = panels.filter(function(p) { return p.id === id })
        return m.length > 0 ? m[0] : null
    }
    function val(id, key) {
        var p = panel(id)
        if (!p || !p.latest || p.latest.value[key] === undefined || p.latest.value[key] === null)
            return "—"
        var v = p.latest.value[key]
        if (Array.isArray(v)) return v.length === 0 ? "none" : v.join(", ")
        if (typeof v === "boolean") return v ? "yes" : "no"
        return String(v)
    }

    ScrollView {
        anchors.fill: parent
        anchors.margins: 14
        contentWidth: availableWidth
        // contentWidth is pinned to the viewport, so a horizontal bar can
        // never be needed - but it is still there, lying across the bottom
        // strip of the page and swallowing clicks that land on it. Text under
        // that strip reads as unselectable for no visible reason.
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
            // Full width, matching every other page. Previously capped at 1100
            // so label/value/provenance read as rows rather than three things
            // scattered across a wide screen; the window now wins.
            width: parent.width
            spacing: 14

            SelectableText {
                text: "Configuration"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "These values are read-only by design. Everything here is "
                    + "declared in a Nix file; nixdash shows what is in effect "
                    + "and where it comes from. Changes to Nix config are "
                    + "snippets you paste - only shell actions below can be run. "
                    + "Drag across the rows to select exactly what you "
                    + "drag, Ctrl+A for a whole section, or Ctrl+Shift+C to "
                    + "copy the section under the pointer as tab-separated "
                    + "text."
            }

            // Two and three columns rather than one tall stack: at full width
            // a single column of sections ran well past the window and the
            // page had to be scrolled to see settings that fit beside what is
            // already on screen. Same breakpoints as SubjectPage.
            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 3 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    title: "NixOS"
                    rows: [
                        { label: "Current generation", value: root.val("generations", "current"),
                          source: "/etc/nixos/configuration.nix → nixos-rebuild switch" },
                        { label: "Reboot pending", value: root.val("generations", "reboot_needed"),
                          source: "/run/booted-system vs /run/current-system",
                          what: "Whether the system you BOOTED is still the \
system that is currently ACTIVE. The two paths below are the comparison: \
<tt>/run/booted-system</tt> is written once at boot and never changes while \
the machine is up; <tt>/run/current-system</tt> is repointed by every \
<tt>nixos-rebuild switch</tt>. Yes here means they differ.",
                          why: "A switch applies most of a new generation \
immediately - services restart, <tt>/etc</tt> is regenerated, your packages \
and <tt>PATH</tt> change - without a reboot. What it cannot replace under a \
running system is whatever was chosen at boot: the <b>kernel</b>, the \
<b>initrd</b>, loaded modules and microcode. So after a switch you are \
running new userspace on the old kernel, and nothing on screen says so \
unless something like this row does.",
                          ifWrong: "<b>Yes is not an error</b>, and usually \
nothing breaks - the old kernel keeps running fine. The case that bites is a \
kernel upgrade: modules for the NEW kernel are in the store while the OLD \
one is running, so loading a module that was not already loaded can fail \
with a version mismatch. Reboot when convenient.<br><br>\
Note this is a different fact from the generation number above it. That can \
advance while this stays <tt>no</tt> - rolling back to the generation you \
happen to be booted into changes one and not the other.",
                          sections: [{ title: "why whole paths are compared",
                          body: "The check compares the two symlinks as \
complete store paths, not just their kernels. That is deliberately \
conservative: a closure differing by a single package still means the system \
you booted is not the system now active, and calling that 'no reboot needed' \
would be a reassurance the measurement does not support.<br><br>\
The cost is that a switch which changed nothing bootable still reports yes. \
That is the right way round - the alternative is staying quiet about a \
kernel change." }] },
                        { label: "Store filesystem", value: root.val("disk", "path"),
                          source: "hardware-configuration.nix" }
                    ]
                }

                // Two Qt sections, because there are two different Qts and
                // conflating them is the mistake this app kept making itself: the
                // one your programs RUN against, and the one you could BUILD
                // with. They are found by completely different mechanisms.
                ConfigSection {
                    Layout.fillWidth: true
                    title: "Qt — what is running"
                    rows: [
                        { label: "Version in use", value: root.val("qt-runtime", "version"),
                          source: "RPATH in the installed binary, not PATH" },
                        { label: "Prefix", value: root.val("qt-runtime", "prefix"),
                          source: "pkgs.qt6.env, via nix/ui.nix" },
                        { label: "Merged environment", value: root.val("qt-runtime", "merged_env"),
                          source: "required for QML and cxx-qt builds" },
                        { label: "Modules linked", value: root.val("qt-runtime", "modules"),
                          source: "" },
                        { label: "Wrapped", value: root.val("qt-runtime", "wrapped"),
                          source: "makeWrapper sets QT_PLUGIN_PATH / QML2_IMPORT_PATH" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    title: "Qt — what could build"
                    rows: [
                        { label: "qmake in use", value: root.val("qt", "qmake"),
                          source: root.val("qt", "source") },
                        { label: "Version", value: root.val("qt", "version"), source: "" },
                        { label: "Prefix", value: root.val("qt", "prefix"), source: "" },
                        { label: "Target spec", value: root.val("qt", "target_spec"), source: "" },
                        { label: "Host tools missing", value: root.val("qt", "tools_missing"),
                          source: "pkgs.qt6.env in your flake's devShell" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    title: "Rust"
                    rows: [
                        { label: "rustc", value: root.val("rust", "rustc"),
                          source: root.val("rust", "rustc_path") },
                        { label: "Host target", value: root.val("rust", "host_target"), source: "" },
                        { label: "Installed targets", value: root.val("rust", "targets"),
                          source: "nixpkgs rustc, or a fenix toolchain in the devShell" },
                        { label: "lld available", value: root.val("rust", "lld_available"),
                          source: "pkgs.lld in the devShell" }
                    ]
                }

                // The only editable section on this page. See its own info button
                // for why these four are writable and nothing else is.
                SettingsSection {
                    id: ownSettings
                    Layout.fillWidth: true
                    apiBase: root.apiBase
                    // A write makes a declared value differ from the running one,
                    // which is exactly when the Apply action appears.
                    onChanged: root.ranAction()
                }

                // The machine's own writable section. This project's dev
                // shell used to sit above it and now lives on the Dev page,
                // beside the build readings it changes.
                SystemSection {
                    Layout.fillWidth: true
                    apiBase: root.apiBase
                    onChanged: root.ranAction()
                }
            }


            // Prepared changes, including the Nix snippets that fill the Qt and
            // Rust gaps shown above - in the place you would look for them.
            ActionsPanel {
                id: configActions
                width: parent.width
                // Sizes to its content, like SubjectPage: the page already
                // scrolls, and a nested 280px scroller took the wheel events
                // without ever scrolling, hiding every action below the fifth.
                height: configActions.implicitHeight
                visible: root.actions.length > 0
                actions: root.actions
                errors: []
                apiBase: root.apiBase
                onRanAction: root.ranAction()
            }
        }
    }
}
