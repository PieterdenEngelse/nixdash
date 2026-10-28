import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// How QML and Rust reach each other, and why every failure here is silent.
//
// Phase 2 of ~/docs/qt-dev-2.md. The prefix page is about finding a Qt; the
// wasm page is about having two of them. This one is about the bridge: a
// Rust object registered as a QML type, and the handful of ways the two
// halves disagree without anything saying so.
//
// Deliberately does NOT re-teach the module URI, the two resource lists or
// the ui/qml symlink. The Qt page's "The QML module" board already covers
// those four, with its own per-row info, and a second copy would be the
// drift this plan's organising rule exists to prevent. This page points at
// it and spends its room on what nothing else says.
//
// The live board is the bridge itself. Every value in it is a Rust
// snake_case property read from QML in camelCase - so the board rendering
// at all is the evidence that #[auto_cxx_name] did its job. A blank row
// there is exactly the failure trap 1 describes.
Item {
    id: root

    Style { id: style }

    property var panels: []
    property string apiBase: ""

    /// The bridge's own values, handed down from Main.qml.
    ///
    /// Not read from a panel: these did not come from the app's background
    /// service over HTTP, they came across the Rust/QML boundary in this
    /// process. That is the whole point of showing them here.
    property string appVersion: ""
    property string builtStamp: ""
    property bool builtExact: false
    property bool browser: false

    function shown(s) {
        return s && String(s).length > 0 ? String(s) : "—"
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
                text: "QML meets Rust"
                font.bold: true
                font.pixelSize: 18
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "A Rust struct is registered as a QML type, and from \
QML it looks like any other object. <tt>cxx-qt</tt> generates the C++ in \
between: the QObject subclass, the properties, the change signals.<br><br>\
<b>Everything on this page fails silently.</b> Not one of these is a \
compile error. A property whose name did not survive the crossing is \
<tt>undefined</tt>, and <tt>undefined</tt> has a string form, so it flows \
onward and surfaces somewhere unrelated. That shared failure mode is the \
reason this page exists - the fixes are all one line."
            }

            // The reading first, and here the reading IS the subject: each
            // row crossed the bridge to get here.
            ConfigSection {
                id: bridge
                width: parent.width
                height: bridge.implicitHeight
                title: "What crossed the bridge, into this window"
                what: "Values from the Rust object, read in QML. Every one \
is <tt>snake_case</tt> in Rust and <tt>camelCase</tt> here."
                why: "<b>This board rendering is the test.</b> These are not \
fetched from the app's background service like every other reading in the \
app - they came across the Rust/QML boundary inside this process. If the \
naming had not matched, the rows would be blank rather than wrong."
                ifWrong: "<b>A dash means the property did not arrive.</b> \
In Rust it is <tt>api_base</tt>; in QML it is <tt>apiBase</tt>, and only \
because <tt>#[auto_cxx_name]</tt> is on the block that declares it. Without \
that, <tt>dash.apiBase</tt> is undefined - and the browser build turns an \
undefined base URL into a local-file read, which reports itself as a \
security policy rather than a typo.<br><br>\
Shown on the browser build too, where <tt>browser</tt> reads yes: the same \
bridge, compiled through Emscripten."
                rows: [
                    { label: "apiBase", value: root.shown(root.apiBase),
                      source: "api_base in Rust - the clearest case of the rename" },
                    { label: "version", value: root.shown(root.appVersion),
                      source: "version - unchanged, because one word has no case to convert" },
                    { label: "built", value: root.shown(root.builtStamp),
                      source: "built - when this binary was produced" },
                    { label: "builtExact", value: root.builtExact ? "yes" : "no",
                      source: "built_exact - two words, so the rename is visible again" },
                    { label: "browser", value: root.browser ? "yes" : "no",
                      source: "browser - yes in the wasm build, no in this window" }
                ]
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                font.pixelSize: style.fontBody
                text: "<b>Four traps, all silent, none of them yours to \
guess.</b> The module URI, the two resource lists and the \
<tt>ui/qml</tt> symlink are the other half of this subject and are already \
on the Qt page's <i>The QML module</i> board, with a note on each - go up \
one level rather than reading them twice here."
            }

            GridLayout {
                width: parent.width
                columns: root.width >= 1500 ? 3 : (root.width >= 900 ? 2 : 1)
                columnSpacing: 14
                rowSpacing: 14

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "1 · Names are not converted for you"
                    what: "cxx-qt 0.7 and later do <b>not</b> case-convert. A \
Rust <tt>api_base</tt> stays <tt>api_base</tt> in QML, so \
<tt>dash.apiBase</tt> is undefined."
                    why: "<b>undefined has a string form</b>, which is what \
makes this travel. It does not throw where you wrote it; it stringifies \
into whatever you built from it and fails much later, somewhere that looks \
unrelated."
                    ifWrong: "<tt>XMLHttpRequest: Using GET on a local file \
is disabled by default</tt> - a security message, from a spelling mistake. \
An undefined base URL made the request a local path.<br><br>\
Annotate per item with <tt>cxx_name</tt>, or put \
<tt>#[auto_cxx_name]</tt> on the whole <tt>extern \"RustQt\"</tt> block, \
which is what this project does and what scales."
                    rows: [
                        { label: "symptom", value: "GET on a local file is disabled",
                          source: "a policy error, nowhere near the cause" },
                        { label: "cause", value: "api_base never became apiBase",
                          source: "cxx-qt >= 0.7 converts nothing by default" },
                        { label: "fix", value: "#[auto_cxx_name] on the block",
                          source: "camelCase for QML, snake_case stays in Rust" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "2 · CMake and build.rs must agree on modules"
                    what: "Every <tt>.qt_module(\"X\")</tt> in \
<tt>build.rs</tt> needs a matching <tt>Qt::X</tt> in \
<tt>cxx_qt_import_crate(QT_MODULES ...)</tt>."
                    why: "<b>Only bites on the CMake path.</b> A pure-Cargo \
crate has nothing to disagree with, so moving one to CMake plus corrosion \
surfaces this out of nowhere, in a build that was fine a moment ago."
                    ifWrong: "<tt>Qt module mismatch between cxx-qt-build and \
CMake!</tt>, naming the missing one.<br><br>\
The odd one out on this page: precise, actionable, and it tells you what to \
do. Listed because its <i>timing</i> is the surprise, not its wording."
                    rows: [
                        { label: "symptom", value: "Qt module mismatch, with the name",
                          source: "an error that is actually helpful" },
                        { label: "cause", value: "two declarations, one list",
                          source: "cxx-qt-build cross-checks them" },
                        { label: "fix", value: "add it in both places",
                          source: "wherever you added the first one" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "3 · A correct fix that looks ineffective"
                    what: "<tt>CXX_QT_AUTORCC_OPTIONS</tt> is not registered \
as <tt>rerun-if-env-changed</tt>, so changing it does not invalidate \
cargo's cache."
                    why: "<b>The build then succeeds in a fraction of a \
second</b>, relinks the stale qrc object, and reproduces the identical \
error. The natural conclusion is that the fix was wrong, and the natural \
next step is to undo it."
                    ifWrong: "The same error as before, after a suspiciously \
fast build. Suspect this whenever a build that should have redone work did \
not take any time.<br><br>\
Force it: <tt>touch &lt;crate&gt;/build.rs</tt>, or \
<tt>cargo clean -p &lt;crate&gt;</tt>."
                    rows: [
                        { label: "symptom", value: "the identical error, instantly",
                          source: "after a change that should have forced a rebuild" },
                        { label: "cause", value: "the variable is not tracked",
                          source: "so cargo believes nothing changed" },
                        { label: "fix", value: "touch build.rs",
                          source: "the thing cargo does watch" }
                    ]
                }

                ConfigSection {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    title: "4 · The QObject warning is not yours"
                    what: "Every build of a cxx-qt crate that registers a QML \
type prints <tt>qmltyperegistrar: Warning: QObject is used as base type but \
cannot be found</tt>."
                    why: "<b>It is upstream behaviour, not your setup.</b> \
qmltyperegistrar resolves base types from metatypes JSON, which Qt's own \
build system supplies with <tt>--foreign-types</tt>. cxx-qt never passes \
that flag - read in <tt>qt-build-utils</tt>, and absent from the whole \
repository. Checked against upstream main on 2026-10-10: identical to \
v0.10.0, so bumping cxx-qt will not fix it."
                    ifWrong: "<b>Nothing is wrong at runtime.</b> The \
inheritance is real compiled C++ and Qt's metaobject system knows it. The \
cost, if any, is static tooling: the generated <tt>.qmltypes</tt> lacks the \
base-class link.<br><br>\
Unverified whether qmlls is actually degraded here - the mechanism is \
established, the symptom is not. Test by opening <tt>qml/Main.qml</tt> and \
checking whether completion on a <tt>Dash</tt> offers <tt>objectName</tt>. \
It is also <i>not</i> the merged-prefix trap: \
<tt>qt6core_metatypes.json</tt> is present and reachable."
                    rows: [
                        { label: "symptom", value: "QObject cannot be found",
                          source: "on every build, in a project that works" },
                        { label: "cause", value: "cxx-qt omits --foreign-types",
                          source: "upstream, deliberate as far as anyone can tell" },
                        { label: "fix", value: "none - ignore it",
                          source: "runtime is unaffected; a local patch would be permanent" }
                    ]
                }
            }

            // Signals get their own board rather than a trap card: there is
            // one trap in them, and it is a consequence of how they work,
            // which has to be said first.
            ConfigSection {
                id: signals_
                width: parent.width
                height: signals_.implicitHeight
                title: "Signals, slots, and the one that disconnects itself"
                what: "<tt>#[qsignal]</tt> in <tt>extern \"RustQt\"</tt> \
declares a signal - never write a body, cxx-qt generates it. The \
function's parameters become the signal's. There is no separate slot: \
<tt>#[qinvokable]</tt> <i>is</i> the slot, callable from QML and \
connectable like one."
                why: "A <tt>#[qproperty]</tt> generates its \
<tt>_changed</tt> signal for free, and that is what makes a QML binding \
update when Rust mutates the property - the board at the top of this page \
stays current through exactly that mechanism. Set connections up in \
<tt>cxx_qt::Initialize</tt>, which runs post-construction with a pinned \
<tt>self</tt>."
                ifWrong: "<b>Connecting returns a \
<tt>QMetaObjectConnectionGuard</tt>, and dropping it disconnects.</b> It is \
RAII, so a connection made in a scope that ends is a connection that ends \
with it - the signal fires and nothing happens, which looks like the signal \
not firing. Store the guard, or call <tt>.release()</tt> for a plain \
<tt>QMetaObjectConnection</tt> that outlives the scope.<br><br>\
For work on another thread, queue back through <tt>CxxQtThread</tt> rather \
than emitting directly."
                rows: [
                    { label: "declare", value: "#[qsignal] fn connected(self: Pin<&mut T>, url: &QUrl)",
                      source: "no body - cxx-qt writes it" },
                    { label: "emit", value: "self.connected(url)",
                      source: "from any &mut method; fires immediately" },
                    { label: "connect", value: "on_connected(..) / connect_connected(.., ConnectionType)",
                      source: "two methods generated per signal" },
                    { label: "keep it", value: ".release()",
                      source: "or store the guard - dropping it disconnects" },
                    { label: "reference", value: "~/Projects/cxx-qt/examples/qml_features/rust/src/signals.rs",
                      source: "upstream's worked example" }
                ]
            }
        }
    }
}
