import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Prepared commands, with the option to run them.
//
// Two things are kept apart here on purpose. The monospace block is the
// command as *prose* - multi-line, commented, often leading with a dry-run you
// should look at first. The Run button executes the engine's `run` spec
// instead: one program, one argument list, shown in the confirmation dialog
// before anything happens. They are not the same text, and the dialog is where
// that becomes visible rather than surprising.
//
// Actions with no `run` (Nix snippets) keep Copy alone - there is nothing to
// execute, and offering a disabled Run would imply there was.
Panel {
    id: root

    Style { id: style }

    property var actions: []
    property var errors: []
    // This panel posts directly rather than routing through Main's getJson.
    // Fetching lives in Main because it is shared polling; a run is a local,
    // one-off consequence of a button in this panel, and its result belongs
    // next to the button that caused it.
    property string apiBase: ""

    // Emitted after a run finishes, so the shell can re-poll: most actions
    // change exactly the state the panels are displaying.
    signal ranAction()

    // id -> { running: bool, ok: bool, text: string }
    property var results: ({})

    function setResult(id, value) {
        var next = {}
        for (var k in root.results)
            next[k] = root.results[k]
        next[id] = value
        root.results = next     // reassign: mutating in place updates nothing
    }
    function resultFor(id) {
        return root.results[id] || null
    }

    // What will actually be executed, as a single readable line. This is the
    // engine's run spec, NOT the displayed command.
    function argvLine(run) {
        if (!run)
            return ""
        var parts = [run.program]
        for (var i = 0; i < run.args.length; ++i) {
            var a = run.args[i]
            // Quote anything that would be ambiguous when read back, so the
            // dialog cannot imply word-splitting that will not happen.
            parts.push(a.indexOf(" ") >= 0 ? JSON.stringify(a) : a)
        }
        var line = parts.join(" ")
        return run.elevate ? "pkexec " + line : line
    }

    function startRun(action) {
        root.setResult(action.id, { running: true, ok: false, text: "" })

        var xhr = new XMLHttpRequest()
        xhr.open("POST", root.apiBase + "/api/actions/" + encodeURIComponent(action.id) + "/run")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            var ok = false
            var text = ""
            try {
                var d = JSON.parse(xhr.responseText)
                if (xhr.status === 200) {
                    ok = d.ok
                    var o = d.outcome
                    // Report the failure reason, not just "it failed".
                    text = o.error ? o.error
                         : ok ? (o.stdout || "done")
                         : "exit " + o.exit_code + (o.stderr ? ": " + o.stderr : "")
                } else {
                    text = d.error || ("HTTP " + xhr.status)
                }
            } catch (e) {
                text = xhr.status === 0
                    ? "engine unreachable"
                    : "HTTP " + xhr.status
            }
            root.setResult(action.id, { running: false, ok: ok, text: text })
            root.ranAction()
        }
        xhr.send()
    }

    // One dialog, reused. The confirmation is the last point at which the
    // consequences are still only text, so it carries the effects and the
    // "if wrong" note rather than a bare are-you-sure.
    Dialog {
        id: confirm
        property var action: null

        anchors.centerIn: parent
        width: Math.min(root.width - 40, 560)
        modal: true
        title: confirm.action ? confirm.action.title : ""
        standardButtons: Dialog.Cancel | Dialog.Ok

        // A header of its own, so this modal carries the same close control
        // as the other two. Dialog draws a title bar when `title` is set, but
        // that bar has no close affordance and no slot to put one in - the
        // property is the text, not the bar - so the bar is replaced rather
        // than decorated.
        header: RowLayout {
            spacing: 8

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.topMargin: 12
                Layout.bottomMargin: 4
                text: confirm.title
                font.bold: true
                font.pixelSize: 15
                elide: Text.ElideRight
            }

            // reject(), not close(). Dismissing a confirmation has to take
            // the same path as Cancel: close() would end the dialog without
            // the rejected() that Cancel emits, so a caller that ever learns
            // to listen for it would silently miss this way out. Nothing is
            // run either way, which is the part that matters here.
            CloseX {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 8
                Layout.rightMargin: 8
                onClicked: confirm.reject()
            }
        }

        onAccepted: if (confirm.action) root.startRun(confirm.action)

        contentItem: Column {
            spacing: 9

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "This will execute, as written:"
            }

            Rectangle {
                width: parent.width
                height: argv.implicitHeight + 12
                radius: 4
                color: palette.alternateBase
                border.color: palette.mid
                // The exact argv about to run as root. Selectable above
                // all else: this is the line you check, and the one you want
                // in a bug report if it did something unexpected.
                SelectableText {
                    id: argv
                    x: 7; y: 6
                    width: parent.width - 14
                    text: root.argvLine(confirm.action ? confirm.action.run : null)
                    font.family: "monospace"
                    font.pixelSize: style.fontBody
                    wrapMode: TextEdit.WrapAnywhere
                }
            }

            // Why this is not simply the command shown in the panel.
            SelectableText {
                width: parent.width
                visible: confirm.action
                         && confirm.action.command.indexOf("\n") >= 0
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "The block in the panel also lists an inspection or \
dry-run step. Only the line above runs."
            }

            SelectableText {
                width: parent.width
                visible: confirm.action && confirm.action.needs_root
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: "Needs root. polkit will ask you to authenticate - \
nixdash has no privilege of its own, so that prompt is what permits it."
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: confirm.action
                      ? "Effects:\n  · " + confirm.action.effects.join("\n  · ")
                      : ""
            }

            SelectableText {
                width: parent.width
                wrapMode: TextEdit.Wrap
                font.pixelSize: style.fontBody
                text: confirm.action && confirm.action.info
                      ? confirm.action.info.if_wrong : ""
            }
        }
    }

    readonly property int needed: actions.filter(function(a) { return a.urgency === "needed" }).length

    // Two kinds of row live in this list, and showing them as one made it
    // useless: a list that never shrinks teaches you to stop reading it.
    //
    // `working` is outstanding work - something is out of date, something
    // failed, something was declared and not applied. Finishing it makes the
    // row go away, which is what a suggestion is for.
    //
    // `standing` is routine: offers that are always here because the thing
    // they do is always available. Collecting garbage and testing that the
    // authorisation prompt works are tools, not problems, and they were
    // sitting in the count making five look like five jobs.
    //
    // Urgency is already the marker - docs/actions.md describes gc-store as
    // firing "always, at routine urgency" - so this reads the field rather
    // than inventing a second one.
    readonly property var working: actions.filter(function(a) { return a.urgency !== "routine" })
    readonly property var standing: actions.filter(function(a) { return a.urgency === "routine" })
    readonly property var ordered: working.concat(standing)

    readonly property var urgencyColors: ({
        "needed":  style.badDot,
        "advised": style.warnDot,
        "routine": style.unknownDot
    })

    title: "Suggested actions"
    subtitle: errors.length > 0
              ? errors.length + " probe(s) failed"
              : working.length === 0
                ? (standing.length > 0 ? "nothing to do · " + standing.length + " always available"
                                       : "nothing to do")
              : working.length + " to do" + (needed > 0 ? ", " + needed + " needed" : "")
    // Routine offers no longer colour the panel. They are always present, so
    // amber for their whole lifetime is amber that means nothing.
    state_: errors.length > 0 ? "stale"
          : needed > 0 ? "bad"
          : working.length > 0 ? "warn"
          : "ok"

    Clipboard { id: actionClip }
    function copyToClipboard(text) {
        actionClip.put(text)
    }

    // What the inherited Ctrl+Shift+C hands back for this pane: every
    // suggested action, each with the command as displayed. Panel's own
    // version would give the headline and nothing else - this panel has no
    // readings, it has a list.
    extraText: {
        var out = ""
        for (var i = 0; i < root.actions.length; i++) {
            var a = root.actions[i]
            out += a.title + "\t" + a.urgency + "\t"
                 + (a.kind === "nix" ? "nix snippet" : "shell") + "\n"
                 + a.command + "\n\n"
        }
        for (var j = 0; j < root.errors.length; j++)
            out += "probe " + root.errors[j].provider + " failed: "
                 + root.errors[j].error + "\n"
        return out
    }

    // Reported so a caller can let the panel size itself, which both pages
    // now do: nesting a fixed-height scroller inside an already scrolling
    // page cut the second action's buttons in half on SubjectPage, and on
    // ConfigPage it swallowed the wheel without ever scrolling.
    contentHeight: actionsCol.implicitHeight

    // No scroller of its own. Both pages size this panel to its content and
    // do the scrolling themselves, and a Flickable accepts wheel events even
    // when it has nothing left to scroll - so with the cursor over the panel
    // the page underneath stopped moving, which reads as a dead mouse wheel
    // rather than as a nested scroll area.
    Item {
        anchors.fill: parent
        clip: true

        Column {
            id: actionsCol
            width: parent.width
            spacing: 10

            SelectableText {
                visible: root.working.length === 0 && root.errors.length === 0
                width: parent.width
                horizontalAlignment: TextEdit.AlignHCenter
                topPadding: 20
                bottomPadding: 10
                text: "Nothing needs doing."
            }

            Repeater {
                // Work first, then the standing offers. One repeater rather
                // than two: the card below is four hundred lines, and a
                // second copy of it would drift from this one.
                model: root.ordered

                Column {
                    width: parent.width
                    spacing: 10

                    // Rendered by the first routine row rather than sitting
                    // between two repeaters, which is what lets both groups
                    // share one delegate.
                    SelectableText {
                        visible: index === root.working.length && root.standing.length > 0
                        width: parent.width
                        topPadding: root.working.length > 0 ? 8 : 0
                        text: "Always available"
                        font.bold: true
                        font.pixelSize: style.fontBody
                        color: style.textMuted
                    }

                Rectangle {
                    width: parent.width
                    height: col.implicitHeight + 18
                    radius: 6
                    color: "transparent"
                    border.color: palette.mid

                    Column {
                        id: col
                        x: 10
                        y: 9
                        width: parent.width - 20
                        spacing: 5

                        Row {
                            spacing: 7
                            width: parent.width

                            Rectangle {
                                width: 8; height: 8; radius: 4
                                anchors.verticalCenter: parent.verticalCenter
                                color: root.urgencyColors[modelData.urgency] || style.unknownDot
                            }
                            // Selectable, like everything else that carries
                            // content rather than chrome.
                            SelectableText {
                                id: titleText
                                text: modelData.title
                                font.bold: true
                                font.pixelSize: style.fontBody
                                color: palette.text
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            // Mechanism and risk: what a bare command line
                            // cannot tell you.
                            InfoButton {
                                anchors.verticalCenter: parent.verticalCenter
                                title: modelData.title
                                what: modelData.info ? modelData.info.what : ""
                                why: modelData.why
                                ifWrong: modelData.info ? modelData.info.if_wrong : ""
                            }
                            // Shell vs Nix: "run this" and "paste this into a
                            // file, then rebuild" are different instructions,
                            // and labelling a flake fragment as a command to
                            // run would be nonsense.
                            Rectangle {
                                width: kindLbl.implicitWidth + 10
                                height: kindLbl.implicitHeight + 3
                                radius: 3
                                color: modelData.kind === "nix" ? style.nixBadgeTint : style.shellBadgeTint
                                anchors.verticalCenter: parent.verticalCenter
                                SelectableText {
                                    id: kindLbl
                                    anchors.centerIn: parent
                                    text: modelData.kind === "nix"
                                          ? "paste into your Nix config"
                                          : "run in a terminal"
                                    font.pixelSize: style.fontBody
                                    color: modelData.kind === "nix" ? style.nixBadgeText : style.shellBadgeText
                                }
                            }
                            Rectangle {
                                visible: modelData.needs_root
                                width: rootLbl.implicitWidth + 10
                                height: rootLbl.implicitHeight + 3
                                radius: 3
                                color: style.rootBadgeTint
                                anchors.verticalCenter: parent.verticalCenter
                                SelectableText {
                                    id: rootLbl
                                    anchors.centerIn: parent
                                    text: "needs root"
                                    font.pixelSize: style.fontBody
                                    color: style.rootBadgeText
                                }
                            }
                            // The badge makes a claim - "this needs root" -
                            // without saying who grants it or how. That is
                            // the whole polkit model, and it is the piece
                            // people are least likely to already know.
                            InfoButton {
                                visible: modelData.needs_root
                                anchors.verticalCenter: parent.verticalCenter
                                title: "Needs root - how that works"
                                what: "This action cannot run as you. nixdash \
asks <b>polkit</b> for permission, polkit asks <i>you</i> to authenticate, and \
only then does the command run as root.<br><br>\
nixdash is not setuid and holds no stored password. It can ask; it cannot \
decide. The dialog you answer <b>is</b> the permission - there is no other \
path, and dismissing it leaves nothing running."
                                why: "A background service has no terminal, \
so <tt>sudo</tt> is not an option: it reads a password from a tty this \
process does not have, and would hang or fail silently. polkit splits the job \
- a root daemon holds the authority, and a small agent in your desktop \
session draws the prompt."
                                ifWrong: "<ul>\
<li><b>No dialog appears, action reports 'not authorised'.</b> Either you \
dismissed it, or no authentication agent is running in this session to draw \
it.</li>\
<li><b><tt>pkexec must be setuid root</tt>.</b> The service is sandboxed in a \
way that blocks setuid - see the <i>When it fails on NixOS</i> tab.</li>\
<li><b>It asks every single time.</b> Normal. Most actions default to \
<tt>auth_admin</tt>, which does not remember; the <tt>_keep</tt> variants \
do, briefly.</li></ul>"
                                sections: [
                                    { title: "The three pieces", body: "\
polkit is not one program. Three cooperate, and knowing which is which turns \
most failures into one-line diagnoses.<br><br>\
<ul>\
<li><b>polkitd</b> - the judge. A daemon running as root. Decides yes, no, or \
'ask'. Has the authority but no screen.</li>\
<li><b>Authentication agent</b> - the face. Runs in <i>your</i> desktop \
session - on Xfce usually <tt>polkit-gnome-authentication-agent-1</tt>. Draws \
the password dialog. Has your screen but no authority.</li>\
<li><b>pkexec</b> - a client. A small setuid program that runs another \
program as root, but only after polkitd agrees.</li>\
</ul><br>\
That split is why an agent must be running: with none, there is nobody to ask, \
and the request fails rather than hanging. nixdash passes \
<tt>--disable-internal-agent</tt> to <tt>pkexec</tt> precisely so it fails \
cleanly instead of blocking forever on a prompt nobody can see.<br><br>\
See the <a href='https://www.freedesktop.org/software/polkit/docs/latest/'>\
polkit documentation</a>." },
                                    { title: "How a decision is made", body: "\
Three inputs.<br><br>\
<b>1. The subject</b> - the process asking. polkitd can see its uid, which \
login session it belongs to, whether that session is local, and whether it is \
currently active. 'Local and active' is why a remote SSH session is often \
treated differently from the person sitting at the machine.<br><br>\
<b>2. The action</b> - a named string, such as \
<tt>org.freedesktop.policykit.exec</tt>. Actions are declared in <tt>.policy</tt> \
XML files shipped by whichever package needs them; this machine has about 33. \
Naming matters: permission is granted per action, not per user wholesale.<br><br>\
<b>3. The rules</b> - each action declares a default:<br>\
<ul>\
<li><tt>yes</tt> - allowed, no prompt</li>\
<li><tt>no</tt> - refused outright</li>\
<li><tt>auth_self</tt> - prove you are you: your own password</li>\
<li><tt>auth_admin</tt> - prove you are an administrator</li>\
<li><tt>*_keep</tt> - as above, but remembered for a short while</li>\
</ul><br>\
JavaScript rules in <tt>/etc/polkit-1/rules.d</tt> can override any of this \
per user, per group or per action - which is how you would make a specific \
action passwordless without weakening everything else." },
                                    { title: "Why not sudo", body: "\
<ul>\
<li><b>Configured by</b> - sudo: <tt>/etc/sudoers</tt>, one file. polkit: \
per-action policies plus JavaScript rules.</li>\
<li><b>Granularity</b> - sudo: which commands a user may run. polkit: named \
actions, with session context.</li>\
<li><b>Prompts via</b> - sudo: the <b>terminal</b>. polkit: a desktop agent, \
in any session.</li>\
<li><b>Mechanism</b> - sudo: a setuid binary. polkit: D-Bus to a daemon.</li>\
</ul><br>\
The prompting row is the decisive one here. nixdash's engine is a systemd \
<i>user service</i> with no controlling terminal. sudo would have nowhere to \
read a password from. polkit's agent lives in your graphical session and can \
draw a dialog regardless of what started the request.<br><br>\
Neither is more secure than the other in general. polkit is finer-grained and \
works for GUI applications; sudo is simpler and better suited to a shell." },
                                    { title: "When it fails on NixOS", body: "\
Two NixOS-specific traps, both of which this project hit.<br><br>\
<b>1. The wrong pkexec.</b> \
<tt>/run/current-system/sw/bin/pkexec</tt> exists and is <tt>r-xr-xr-x</tt> - \
<b>not setuid</b>. The setuid copy is a separate wrapper at \
<tt>/run/wrappers/bin/pkexec</tt>, mode <tt>4511</tt>, where that leading 4 is \
the setuid bit. NixOS keeps setuid binaries in their own directory. Run the \
system-profile one and pkexec refuses immediately, which reads like a broken \
polkit install rather than the wrong path to the right program.<br><br>\
<b>2. A sandbox that silently disables setuid.</b> \
<tt>NoNewPrivileges=yes</tt> makes the setuid bit a no-op, so pkexec can never \
escalate. Worse, several systemd options are implemented with <b>seccomp</b> - \
<tt>SystemCallFilter</tt>, <tt>SystemCallArchitectures</tt>, \
<tt>LockPersonality</tt>, <tt>MemoryDenyWriteExecute</tt>, \
<tt>RestrictRealtime</tt>, <tt>RestrictSUIDSGID</tt> - and systemd cannot \
install a seccomp filter in an unprivileged user unit without also setting \
NoNewPrivileges. They enable it behind your back.<br><br>\
The unit then lies about it:<br>\
<tt>systemctl --user show UNIT -p NoNewPrivileges</tt> → <tt>no</tt><br>\
<tt>grep NoNewPrivs /proc/&lt;pid&gt;/status</tt> → <tt>1</tt> ← the \
truth<br><br>\
Always check <tt>/proc</tt>. And note the flag is <b>inherited and can never \
be cleared</b>, so a process keeps it until genuinely restarted - a restart \
that looks like a no-op is not.<br><br>\
See <a href='https://www.freedesktop.org/software/systemd/man/systemd.exec.html'>\
systemd.exec(5)</a>." }
                                ]
                            }
                        }

                        SelectableText {
                            id: whyText
                            width: parent.width
                            text: modelData.why
                            font.pixelSize: style.fontBody
                            color: palette.text
                            wrapMode: TextEdit.Wrap
                        }

                        // The command. Selectable so it can be copied by hand
                        // too - the button is a convenience, not the only way.
                        Rectangle {
                            width: parent.width
                            height: cmd.implicitHeight + 12
                            radius: 4
                            color: palette.alternateBase
                            border.color: palette.mid

                            SelectableText {
                                id: cmd
                                x: 7; y: 6
                                width: parent.width - 14
                                text: modelData.command
                                wrapMode: TextEdit.Wrap
                                font.family: "monospace"
                                font.pixelSize: style.fontBody
                                color: palette.text
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 8

                            Button {
                                text: "Copy"
                                onClicked: root.copyToClipboard(modelData.command)
                            }
                            // Copy and Run put *different text* in play. That
                            // is the single most important thing about this
                            // panel, so both buttons say so from their own
                            // side rather than relying on you to infer it.
                            InfoButton {
                                anchors.verticalCenter: parent.verticalCenter
                                title: "Copy"
                                what: "Copies the block above to the \
clipboard <b>exactly as shown</b> - every line, including comments and any \
inspection or dry-run step. That is deliberately more than the Run button \
executes."
                                why: "Pasting into a terminal runs it as \
<i>you</i>, in <i>your</i> shell, with your PATH and whatever toolchain your \
current <tt>nix develop</tt> provides. For the Qt and Rust suggestions that \
is usually what you want, because those depend on the environment you are \
standing in - and the engine's environment is not yours."
                                ifWrong: "<ul>\
<li><b>Pasting the whole block runs every line in it.</b> For garbage \
collection that is the dry-run <i>and</i> the deletion. Read it, then keep the \
line you actually meant.</li>\
<li><b>Nothing on the clipboard.</b> Qt's clipboard needs a user gesture; if \
the paste comes up empty, select the text in the box and copy it by hand - it \
is selectable for exactly this reason.</li>\
<li><b>A Nix snippet does not go in a terminal.</b> It goes into a \
<tt>.nix</tt> file, and then you rebuild. The badge on the action says \
which kind it is.</li></ul>"
                                sections: [
                                    { title: "Copy vs Run", body: "\
These two buttons put <b>different text</b> in play. It is the single most \
important thing about this panel.<br><br>\
<ul>\
<li><b>Text</b> - Copy: the whole displayed block. Run: one explicit program \
plus arguments.</li>\
<li><b>Runs as</b> - Copy: you, interactively. Run: the app's background \
service, via a polkit prompt.</li>\
<li><b>Environment</b> - Copy: your shell, with your PATH and your \
<tt>nix develop</tt>. Run: the background service's own.</li>\
<li><b>Dry-run line</b> - Copy: included. Run: excluded.</li>\
<li><b>Nix snippets</b> - Copy: yes, that is the point. Run: refused, there \
is nothing to execute.</li>\
</ul><br>\
Neither is the \"safe\" one. Copy gives you a chance to read and edit before \
anything happens, but pasting a whole block unread is how you run a deletion \
you only meant to preview. Run executes exactly one known line, but does it \
with root behind a prompt that is easy to click through." },
                                    { title: "Where snippets go", body: "\
Actions badged <i>paste into your Nix config</i> are configuration, not \
commands. Each one belongs in a file you own:<br><br>\
<ul>\
<li><b>Qt merged prefix</b> - the devShell of whichever flake builds your Qt \
project. It replaces separate <tt>qt6</tt> inputs with <tt>pkgs.qt6.env</tt>, \
because nixpkgs' qmake has its prefix baked in and a <tt>symlinkJoin</tt> is \
ignored.</li>\
<li><b>Rust wasm target</b> - the same devShell. nixpkgs' rustc ships the \
host target only, so a cross build fails with <i>can't find crate for std</i>. \
See <a href='https://github.com/nix-community/fenix'>fenix</a> and the \
<a href='https://doc.rust-lang.org/rustc/platform-support.html'>platform \
support list</a>.</li>\
<li><b>lld</b> - the devShell again, as a package.</li>\
</ul>\
After pasting, rebuild: <tt>nixos-rebuild switch</tt> for system config, \
<tt>home-manager switch</tt> for user config, or simply re-entering \
<tt>nix develop</tt> for a devShell change.<br><br>\
This is why the Config page has no input fields. The machine is configured \
declaratively; a box you could type into would either write somewhere Nix \
later overwrites, or fight Nix outright." }
                                ]
                            }
                            // Absent, not disabled, when there is nothing to
                            // execute: a greyed-out Run would suggest the
                            // snippet is runnable and something is stopping it.
                            Button {
                                visible: !!modelData.run
                                enabled: {
                                    var r = root.resultFor(modelData.id)
                                    return !(r && r.running)
                                }
                                text: {
                                    var r = root.resultFor(modelData.id)
                                    if (r && r.running)
                                        return "Running…"
                                    return modelData.needs_root ? "Run (asks for root)" : "Run"
                                }
                                onClicked: {
                                    confirm.action = modelData
                                    confirm.open()
                                }
                            }
                            // The control that changes your machine gets its
                            // own explanation, separate from the action's.
                            // The action's info says what the command does;
                            // this says what pressing the button does, which
                            // is a different question and the one people get
                            // wrong - above all that it does not run the text
                            // in the box.
                            InfoButton {
                                visible: !!modelData.run
                                anchors.verticalCenter: parent.verticalCenter
                                title: "Run"
                                what: "Asks the engine to execute <i>this \
action</i>, by name. The engine looks the action up and runs the program and \
argument list it already holds for it - the exact line shown in the \
confirmation dialog.<br><br>It does <b>not</b> run the text in the box above. \
That text is written for a person: multi-line, commented, and often leading \
with an inspection or dry-run step you are meant to read before the real \
command."
                                why: "The engine holds no privilege of its \
own. It is not setuid and carries no stored credential. Anything needing root \
goes through <tt>pkexec</tt>, which hands the decision to <a \
href='https://www.freedesktop.org/software/polkit/docs/latest/'>polkit</a>, \
which asks you. <b>The prompt is the authorisation</b> - dismiss it and \
nothing happens."
                                ifWrong: "<ul>\
<li><b>Nothing appears to happen.</b> The polkit prompt was dismissed, or no \
authentication agent is running in this session.</li>\
<li><b>It succeeds but the machine looks unchanged.</b> The command ran in the \
<i>engine's</i> environment - the systemd user service's - not your shell's. \
PATH and any Qt or Rust toolchain differ from a terminal inside \
<tt>nix develop</tt>.</li>\
<li><b>The button is missing.</b> That action has nothing to execute: it is a \
Nix snippet, which is configuration for a file you own rather than a \
command.</li></ul>"
                                sections: [
                                    { title: "What actually runs", body: "\
Two different pieces of text are in play, and conflating them is the mistake \
this panel exists to prevent.<br><br>\
<b>The box above is prose.</b> Garbage collection displays:<br>\
<tt>nix-collect-garbage --dry-run</tt><br>\
<tt># then, to actually delete:</tt><br>\
<tt>sudo nix-collect-garbage -d</tt><br><br>\
Executed verbatim that would run the survey <i>and</i> the deletion, back to \
back, having shown nobody the survey - and the embedded <tt>sudo</tt> wants a \
terminal this background service does not have.<br><br>\
<b>Run uses a separate, explicit spec</b> - one program, one argument list, \
decided when the action was written. For that action it is \
<tt>nix-collect-garbage -d</tt> and nothing else. The confirmation dialog \
shows you that line, not the prose, and says so when the two differ.<br><br>\
There is no shell involved. The program and its arguments go straight to \
<tt>exec</tt>, so nothing is word-split, glob-expanded or interpreted - which \
matters because some arguments come from system state, such as the name of a \
failed unit." },
                                    { title: "Privileges", body: "\
Root comes from <tt>pkexec</tt>, never <tt>sudo</tt>. sudo wants a terminal \
and a password on stdin; a background service has neither and would hang or \
fail silently. pkexec raises a desktop prompt that you answer.<br><br>\
<i>The full picture - what polkit is, the three programs involved, how a \
decision is reached, and the two NixOS traps - is behind the info button on \
the <b>needs root</b> badge above.</i><br><br>\
<b>What protects this</b><ul>\
<li>The request names an <i>action</i>, never a command. The endpoint takes no \
body - there is no field for a program, an argument or a flag. The set of \
things the engine can ever execute is fixed when it is built.</li>\
<li>Nix snippets are refused outright rather than improvised into some \
command.</li>\
<li>The API is restricted to loopback origins, so a page in your browser \
cannot provoke a prompt you did not go looking for.</li></ul>\
<b>What this costs</b><br>\
Until this feature existed the engine executed nothing at all, which made it \
auditable in a way it no longer is. The API has no authentication, so anything \
that can reach it can <i>ask</i> for a privileged action. The polkit prompt is \
the only thing between that and a rebuild. That trade was made deliberately \
and is written up in the project's <tt>docs/actions.md</tt>." },
                                    { title: "Troubleshooting", body: "\
<b>\"not authorised\"</b><br>\
The prompt was dismissed, or no polkit agent is running in this session to \
display it. On Xfce that agent is \
<tt>polkit-gnome-authentication-agent-1</tt>; check it is running.<br><br>\
<b>\"pkexec could not run the command\"</b> / <tt>pkexec must be setuid \
root</tt><br>\
The service is sandboxed in a way that blocks setuid. Confirm with \
<tt>grep NoNewPrivs /proc/&lt;pid&gt;/status</tt> - note that \
<tt>systemctl --user show</tt> can report <tt>NoNewPrivileges=no</tt> while \
the kernel says <tt>1</tt>, because several <a \
href='https://www.freedesktop.org/software/systemd/man/systemd.exec.html'>\
systemd sandbox options</a> are seccomp-based and imply it in an unprivileged \
user unit. The flag is inherited and can never be cleared, so a stale process \
keeps it until genuinely restarted.<br><br>\
<b>It hangs</b><br>\
Long actions are not stuck: a rebuild legitimately takes minutes. Output is \
collected and shown when it finishes, with a 30 minute ceiling.<br><br>\
<b>Rolling back</b><br>\
Most actions here are reversible by generation - see \
<a href='https://nixos.org/manual/nixos/stable/'>the NixOS manual</a>. \
Garbage collection with <tt>-d</tt> is the exception: it deletes the \
generations that would be your rollback targets." }
                                ]
                            }
                            SelectableText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.effects.join("  ·  ")
                                font.pixelSize: style.fontBody
                                wrapMode: TextEdit.NoWrap
                                clip: true
                                width: Math.max(0, parent.width - 230)
                            }
                        }

                        // Outcome of the last run of this action: exit status,
                        // or the reason it could not start. Shown rather than
                        // logged, because a privileged action that quietly did
                        // nothing is the worst case.
                        Rectangle {
                            property var res: root.resultFor(modelData.id)
                            visible: res && !res.running && res.text !== ""
                            width: parent.width
                            height: resLbl.implicitHeight + 12
                            radius: 4
                            color: res && res.ok ? style.okTint : style.badTint
                            border.color: res && res.ok ? style.okDot : style.badDot

                            // Selectable above all the others: a failure
                            // message is the thing you most want to paste
                            // somewhere else.
                            SelectableText {
                                id: resLbl
                                x: 7; y: 6
                                width: parent.width - 14
                                text: parent.res
                                      ? (parent.res.ok ? "✓ " : "✗ ") + parent.res.text
                                      : ""
                                color: parent.res && parent.res.ok ? style.okText : style.badText
                                font.family: "monospace"
                                font.pixelSize: style.fontBody
                                wrapMode: TextEdit.Wrap
                            }
                        }
                    }
                }
                }
            }

            Repeater {
                model: root.errors
                SelectableText {
                    id: errText
                    width: parent.width
                    text: "probe " + modelData.provider + " failed: " + modelData.error
                    color: style.warnDot
                    font.pixelSize: style.fontBody
                    wrapMode: TextEdit.Wrap
                }
            }
        }
    }
}
