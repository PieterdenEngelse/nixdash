import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Why there is no single Qt on this machine.
//
// The first teaching page under Dev > Qt, and the one everything else
// depends on: three of the four boards on the Qt page are views of this one
// fact, and most of what goes wrong in a cxx-qt build here is this fact
// being met for the first time.
//
// Written against readings rather than beside them. The claim "your prefix
// is missing qmltyperegistrar" is worth nothing from a document and
// everything from a panel that just measured it, and that measurement is
// the only thing this app can do that ~/docs/qt.md cannot. The build
// recipes stay there; what is on screen here is what can be shown.
Item {
    id: root

    Style { id: style }

    property var panels: []
    property string apiBase: ""

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
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
            width: parent.width
            spacing: 14

            SelectableText {
                text: "Why there is no single Qt"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "On most systems Qt is one directory. Here it is \
several, and a build has to be told which one to believe.<br><br>\
nixpkgs ships Qt as separate store paths - <tt>qtbase</tt>, \
<tt>qtdeclarative</tt>, <tt>qtsvg</tt> and so on - each immutable and each \
containing only its own part. That is not an accident to work around: it is \
what makes two projects able to use different Qt versions on one machine \
without either of them knowing. The cost lands on anything that expects a \
single prefix, and <b>cxx-qt expects a single prefix</b>."
            }

            // The reading first, then what it means. Someone arriving here
            // has a build that failed; the first useful thing is their own
            // numbers, not a paragraph.
            ConfigSection {
                id: yours
                width: parent.width
                height: yours.implicitHeight
                title: "On this machine, right now"
                what: "What the Qt that answered actually contains. These \
are the same readings as the Qt page's first two boards, repeated here \
because the explanation below is about them."
                why: "A prefix is only ever missing something relative to \
what is asking. cxx-qt asks for four host tools; two of them live in \
qtdeclarative, which is a different store path from the one qmake reports."
                ifWrong: "<b>Incomplete here while your builds work is the \
normal reading, not a fault.</b> The qmake this app finds is usually the one \
inside its own files - a runtime copy, where host tools are absent by \
design. The one a build uses is your dev shell's <tt>QMAKE</tt>, which this \
app cannot see."
                rows: [
                    { label: "qmake found via", value: root.val("qt", "source"),
                      source: "QMAKE, then PATH, then this app's own files" },
                    { label: "its prefix", value: root.val("qt", "prefix"),
                      source: "one store path - the question is whether it is enough" },
                    { label: "tools present", value: root.val("qt", "tools_found"),
                      source: "these ship in qtbase" },
                    { label: "tools absent", value: root.val("qt", "tools_missing"),
                      source: "these ship in qtdeclarative, which is elsewhere" },
                    { label: "complete", value: root.val("qt", "prefix_complete"),
                      source: "whether one prefix answers every question cxx-qt asks" }
                ]
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "<b>Three traps follow from that split</b>, and all \
three were paid for on this machine rather than read about. Each has a \
symptom you will see before you know the cause."
            }

            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 3 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "1 · One merged prefix"
                    what: "cxx-qt interrogates a single <tt>qmake</tt> for \
headers, libraries AND the host tools that generate code: <tt>moc</tt>, \
<tt>rcc</tt>, <tt>qmltyperegistrar</tt>, <tt>qmlcachegen</tt>."
                    why: "<b>Listing the packages does not help.</b> \
<tt>buildInputs = [ qtbase qtdeclarative ]</tt> puts both in the build, but \
qmake still reports only qtbase's prefix - and the prefix is the only thing \
cxx-qt asks. The two tools it cannot find are the two that live elsewhere."
                    ifWrong: "<b>A plain <tt>symlinkJoin</tt> does not fix \
it either</b>, which is the part that costs an afternoon: nixpkgs' qmake has \
its prefix compiled in and ignores the join. Verified here - \
<tt>QT_INSTALL_PREFIX</tt> still pointed at qtbase.<br><br>\
<tt>pkgs.qt6.env</tt> works because it does something a join cannot: it \
merges the outputs and copies the real qmake binary next to a generated \
<tt>qt.conf</tt>, so qmake resolves its prefix from where it is standing."
                    rows: [
                        { label: "symptom", value: "fails at code generation",
                          source: "not at configure time - the build gets a long way first" },
                        { label: "cause", value: "qmake reports one prefix",
                          source: "and the tools it names are not all in it" },
                        { label: "fix", value: "pkgs.qt6.env",
                          source: "merge, then point QMAKE at the merged prefix" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "2 · -lGLX and -lOpenGL"
                    what: "Qt6Gui and Qt6OpenGL carry <tt>.prl</tt> files \
that reference <tt>-lGLX</tt> and <tt>-lOpenGL</tt>. Those come from \
<tt>libglvnd</tt>, which is not part of Qt."
                    why: "<b>It must go in <tt>buildInputs</tt>, not \
<tt>packages</tt>.</b> Only buildInputs feed the cc wrapper's \
<tt>NIX_LDFLAGS</tt> with the <tt>-L</tt> the linker needs. A package in \
<tt>mkShell</tt>'s <tt>packages</tt> is on PATH and invisible to the linker, \
which is a distinction nothing in the error message hints at."
                    ifWrong: "<tt>cannot find -lGLX</tt> at link time, after \
everything compiled. The names in that message belong to a library you never \
mentioned, which is why it reads as a broken Qt rather than a missing input."
                    rows: [
                        { label: "symptom", value: "cannot find -lGLX",
                          source: "at link time, after a clean compile" },
                        { label: "cause", value: "libglvnd absent from the link",
                          source: "Qt's .prl files reference it; Qt does not provide it" },
                        { label: "fix", value: "buildInputs = [ libglvnd ]",
                          source: "buildInputs, not packages - only one of them reaches the linker" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "3 · QMAKE gets clobbered"
                    what: "Under <tt>nix build</tt> - not in a dev shell - \
nixpkgs' <tt>qtbase-setup-hook.sh</tt> unconditionally exports \
<tt>QMAKE</tt> pointing at qtbase."
                    why: "<b>It silently overrides the attribute you set.</b> \
Setup hooks run before the build phases, so a <tt>QMAKE</tt> given in the \
derivation is replaced before anything uses it, and cxx-qt is pointed back \
at the unmerged prefix you went to trouble to avoid."
                    ifWrong: "<tt>Could not find a prl path for Qt module: \
QuickControls2</tt> - a message about a module, from a problem about an \
environment variable.<br><br>\
Re-export it in <tt>preBuild</tt>, which runs after the hooks. The dev shell \
is unaffected, so this one appears only when you package the thing that has \
been building fine for weeks."
                    rows: [
                        { label: "symptom", value: "no prl path for QuickControls2",
                          source: "under nix build only - never in the dev shell" },
                        { label: "cause", value: "a setup hook re-exports QMAKE",
                          source: "after your attribute, before the build" },
                        { label: "fix", value: "re-export in preBuild",
                          source: "the first phase that runs after the hooks" }
                    ]
                }
            }

            // The whole fix in one place, because three boards of reasoning
            // still leave you needing something to type.
            ConfigSection {
                id: recipe
                width: parent.width
                height: recipe.implicitHeight
                title: "What this project does"
                what: "The merged prefix as it appears in this repository's \
<tt>flake.nix</tt>, which is the worked example for all three traps above."
                why: "A snippet you can read beside the readings that prove \
it worked is worth more than one in a document - the board at the top of \
this page is this flake's result."
                ifWrong: "<tt>qtsvg</tt> and <tt>qtshadertools</tt> are in \
the list because this app uses them. The one that matters for the traps \
above is <tt>qtdeclarative</tt>: it is where the two missing host tools \
live.<br><br>\
The long form, including the WebAssembly half, is in \
<tt>~/docs/qt.md</tt>."
                rows: [
                    { label: "the merge", value: "pkgs.qt6.env \"nixdash-qt-env\" [ qtdeclarative qtsvg qtshadertools ]",
                      source: "flake.nix - one prefix containing every part this app needs" },
                    { label: "the pointer", value: "QMAKE = \"${qtEnv}/bin/qmake\"",
                      source: "cxx-qt reads this; without it, it falls back to whatever is on PATH" },
                    { label: "the linker", value: "buildInputs = [ pkgs.libglvnd ]",
                      source: "trap 2 - buildInputs, so the cc wrapper sees it" },
                    { label: "under nix build", value: "preBuild = ''export QMAKE=${qtEnv}/bin/qmake''",
                      source: "trap 3 - after the setup hook has had its turn" }
                ]
            }
        }
    }
}
