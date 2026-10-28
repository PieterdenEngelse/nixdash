//! Inside a `Text` or a `Label`, the palette is reached through `theme`.
//!
//! `Text` and everything derived from it carry their own `style` property -
//! the `QQuickText::Normal/Outline/Raised` enum - and it shadows the
//! `Style { id: style }` declared above. A `style.fontBody` written inside one
//! resolves to that enum, yields undefined, and the binding keeps its default
//! instead of erroring. So each component exposes
//! `readonly property var theme: style`, and use sites inside a text item read
//! `root.theme.fontBody`.
//!
//! **Nothing else catches this.** `qml-check` reports `clean` on the shadowed
//! form - an earlier comment in `MemoryPanel.qml` claimed otherwise and was
//! wrong. The app is no guard either, because the failure renders rather than
//! throws: the labels draw every frame, in the right places, with the right
//! text, in a default colour and a default size on a dark panel. Only looking
//! at the rendered pixels finds it, which is to say it is found by accident or
//! not at all. Two of them sat in `Main.qml`'s navigation trail - the `\u{203a}`
//! separators at the subject and topic levels - until someone read the panel.
//!
//! That is the argument for a test rather than a convention: the mistake is
//! invisible at every stage that normally reports mistakes, and it is the
//! natural thing to type, because `style.fontBody` is correct everywhere in the
//! file except inside the one kind of block where it silently is not.
//!
//! Lives in the engine's test directory for the dull reason that this is the
//! only test harness the project has; it reads `../qml` as data.

use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
};

/// Qt types whose instances carry `QQuickText::style`.
///
/// `TextEdit` and `TextInput` do not - they descend from `QQuickImplicitSizeItem`,
/// not `QQuickText` - which is why `SelectableText.qml` can and does read
/// `style` directly. `TextArea` and `TextField` are their Controls wrappers and
/// are likewise unaffected.
const QT_SHADOWING: &[&str] = &["Text", "Label"];

/// Reads that have earned their place, with the argument for them.
///
/// Expected to stay empty. There is no cost to `theme`: it is the same object
/// under a name that nothing shadows.
const EXEMPT: &[(&str, &str)] = &[];

fn qml_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine/ has a parent")
        .join("qml")
}

fn qml_files() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(qml_dir()) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) == Some("qml") {
                out.push(p);
            }
        }
    }
    out.sort();
    out
}

/// What a `{` opened.
#[derive(Debug)]
enum Frame {
    /// `Ident {` - a QML object, whose type name decides whether `style` is
    /// shadowed for everything within it.
    Type(String),
    /// Any other brace: a function body, a grouped property, an `if`.
    Block,
    /// A `${` interpolation inside a template literal. Its contents are code.
    Interp,
}

/// Every dotted member access in `src`, as (line, path, shadowed).
///
/// `shadowed` is true when some enclosing object is a type in `shadowing`,
/// which is the whole question - a given `style.fontBody` is correct or wrong
/// depending only on what encloses it, so the scanner has to track scope and
/// cannot be a grep.
///
/// Comments and string bodies are skipped, because a comment that writes
/// `style.fontBody` to name the mistake is not making it; `MemoryPanel.qml`
/// and `Main.qml` both do exactly that, directly above the property that
/// exists to avoid it. Template literals are skipped too, but their `${}`
/// interpolations are not - that is live code.
fn accesses(src: &str, shadowing: &HashSet<String>) -> Vec<(usize, String, bool)> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut stack: Vec<Frame> = Vec::new();
    // Backtick nesting: a template literal we are inside, whose `${}` we may
    // currently be within.
    let mut templates = 0usize;
    let mut in_template = false;
    let mut line = 1usize;
    let mut i = 0usize;

    let is_ident = |ch: char| ch.is_ascii_alphanumeric() || ch == '_';

    while i < c.len() {
        if in_template {
            match c[i] {
                '\n' => {
                    line += 1;
                    i += 1;
                }
                '\\' => i = (i + 2).min(c.len()),
                '`' => {
                    in_template = false;
                    templates -= 1;
                    i += 1;
                }
                '$' if c.get(i + 1) == Some(&'{') => {
                    in_template = false;
                    stack.push(Frame::Interp);
                    i += 2;
                }
                _ => i += 1,
            }
            continue;
        }

        match c[i] {
            '\n' => {
                line += 1;
                i += 1;
            }
            '/' if c.get(i + 1) == Some(&'/') => {
                while i < c.len() && c[i] != '\n' {
                    i += 1;
                }
            }
            '/' if c.get(i + 1) == Some(&'*') => {
                i += 2;
                while i < c.len() && !(c[i] == '*' && c.get(i + 1) == Some(&'/')) {
                    if c[i] == '\n' {
                        line += 1;
                    }
                    i += 1;
                }
                i = (i + 2).min(c.len());
            }
            '"' | '\'' => {
                let quote = c[i];
                i += 1;
                while i < c.len() && c[i] != quote {
                    if c[i] == '\\' && i + 1 < c.len() {
                        if c[i + 1] == '\n' {
                            line += 1;
                        }
                        i += 2;
                        continue;
                    }
                    if c[i] == '\n' {
                        line += 1;
                    }
                    i += 1;
                }
                i += 1;
            }
            '`' => {
                in_template = true;
                templates += 1;
                i += 1;
            }
            '{' => {
                // Whatever identifier sits immediately before the brace names
                // the type being instantiated. A `)` or a `:` before it means
                // a plain block instead.
                let mut j = i;
                while j > 0 && c[j - 1].is_whitespace() {
                    j -= 1;
                }
                let end = j;
                while j > 0 && (is_ident(c[j - 1]) || c[j - 1] == '.') {
                    j -= 1;
                }
                let name: String = c[j..end].iter().collect();
                // `Rectangle` and `QtQuick.Item` are types; `else`, `try` and
                // an empty match are not. A QML type name is capitalised, and
                // a qualified one is capitalised after its last dot.
                let leaf = name.rsplit('.').next().unwrap_or("");
                let is_type = leaf
                    .chars()
                    .next()
                    .map(|ch| ch.is_ascii_uppercase())
                    .unwrap_or(false);
                stack.push(if is_type {
                    Frame::Type(leaf.to_string())
                } else {
                    Frame::Block
                });
                i += 1;
            }
            '}' => {
                // Closing a `${}` hands us back to the template literal that
                // opened it.
                if matches!(stack.pop(), Some(Frame::Interp)) && templates > 0 {
                    in_template = true;
                }
                i += 1;
            }
            ch if ch.is_ascii_alphabetic() || ch == '_' => {
                // The head of the path, which is what decides whose scope is
                // being read. Consume the whole dotted path so that the
                // `theme` in `root.theme.fontBody` is not mistaken for a head
                // of its own.
                let start = i;
                while i < c.len() && is_ident(c[i]) {
                    i += 1;
                }
                let mut end = i;
                loop {
                    let mut j = i;
                    while j < c.len() && (c[j] == ' ' || c[j] == '\t') {
                        j += 1;
                    }
                    if c.get(j) != Some(&'.') {
                        break;
                    }
                    j += 1;
                    while j < c.len() && (c[j] == ' ' || c[j] == '\t') {
                        j += 1;
                    }
                    if !c.get(j).map(|&x| is_ident(x)).unwrap_or(false) {
                        break;
                    }
                    while j < c.len() && is_ident(c[j]) {
                        j += 1;
                    }
                    i = j;
                    end = j;
                }
                let path: String = c[start..end]
                    .iter()
                    .filter(|ch| !ch.is_whitespace())
                    .collect();
                if path.contains('.') {
                    let shadowed = stack.iter().any(|f| match f {
                        Frame::Type(t) => shadowing.contains(t),
                        _ => false,
                    });
                    out.push((line, path, shadowed));
                }
            }
            _ => i += 1,
        }
    }
    out
}

/// The type a component's root object instantiates.
fn root_type(src: &str) -> Option<String> {
    let c: Vec<char> = src.chars().collect();
    let mut i = 0usize;
    while i < c.len() {
        match c[i] {
            '/' if c.get(i + 1) == Some(&'/') => {
                while i < c.len() && c[i] != '\n' {
                    i += 1;
                }
            }
            '/' if c.get(i + 1) == Some(&'*') => {
                i += 2;
                while i < c.len() && !(c[i] == '*' && c.get(i + 1) == Some(&'/')) {
                    i += 1;
                }
                i = (i + 2).min(c.len());
            }
            ch if ch.is_ascii_uppercase() => {
                let start = i;
                while i < c.len() && (c[i].is_ascii_alphanumeric() || c[i] == '_' || c[i] == '.') {
                    i += 1;
                }
                let name: String = c[start..i].iter().collect();
                let mut j = i;
                while j < c.len() && c[j].is_whitespace() {
                    j += 1;
                }
                if c.get(j) == Some(&'{') {
                    return name.rsplit('.').next().map(str::to_string);
                }
            }
            _ => i += 1,
        }
    }
    None
}

/// Qt's shadowing types, plus every component that inherits the property by
/// rooting on one.
///
/// Nothing in `qml/` roots on a `Text` today, so this resolves to exactly
/// `QT_SHADOWING`. It is computed rather than hardcoded so that the first
/// component that does root on one does not quietly fall outside the test -
/// the instances of such a component would carry `style` just as a bare `Text`
/// does, and the mistake would read identically.
fn shadowing_types() -> HashSet<String> {
    let mut roots: HashMap<String, String> = HashMap::new();
    for path in qml_files() {
        let Ok(src) = fs::read_to_string(&path) else {
            continue;
        };
        if let Some(root) = root_type(&src) {
            let name = path.file_stem().unwrap().to_string_lossy().to_string();
            roots.insert(name, root);
        }
    }

    let mut out: HashSet<String> = QT_SHADOWING.iter().map(|s| s.to_string()).collect();
    // Follow each component up to a Qt type, with a hop limit rather than a
    // visited set because a cycle is a broken tree, not a case to support.
    for name in roots.keys() {
        let mut cur = name.clone();
        for _ in 0..roots.len() + 1 {
            let Some(next) = roots.get(&cur) else { break };
            if QT_SHADOWING.contains(&next.as_str()) {
                out.insert(name.clone());
                break;
            }
            cur = next.clone();
        }
    }
    out
}

fn violations(name: &str, src: &str, shadowing: &HashSet<String>) -> Vec<String> {
    accesses(src, shadowing)
        .into_iter()
        .filter(|(_, path, shadowed)| *shadowed && path.split('.').next() == Some("style"))
        .filter(|(line, path, _)| {
            let key = format!("{name}:{line}:{path}");
            !EXEMPT.iter().any(|(k, _)| *k == key)
        })
        .map(|(line, path, _)| {
            format!(
                "{name}:{line} reads `{path}` inside a Text or a Label.\n    \
                 There `style` is the QQuickText enum, not the palette, so this \
                 yields undefined and the binding silently keeps its default. \
                 Write `root.theme.{}` instead.",
                path.split_once('.').map(|(_, rest)| rest).unwrap_or("")
            )
        })
        .collect()
}

#[test]
fn no_text_or_label_reaches_the_palette_through_style() {
    let shadowing = shadowing_types();
    let mut failures = Vec::new();
    let mut scanned = 0usize;

    for path in qml_files() {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let Ok(src) = fs::read_to_string(&path) else {
            continue;
        };
        scanned += 1;
        failures.extend(violations(&name, &src, &shadowing));
    }

    assert!(
        scanned > 20,
        "scanned only {scanned} qml files - the scanner is broken"
    );
    assert!(
        failures.is_empty(),
        "{} shadowed palette read(s):\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}

/// A scanner that found nothing would pass the test above on an empty read, so
/// this pins what it does see in the real tree.
///
/// Two claims, because each alone is weak. That it recognises `Text` and
/// `Label` scopes at all is shown by how much it reads inside them - 33
/// member accesses at the time of writing, which is the text of the app. That
/// it recognises the *right* scopes is shown by the three `theme` reads: a
/// `theme` read outside a text item would be pointless, since outside one
/// there is nothing to work around, so every one of them must land inside.
/// If the brace tracking drifted, that correspondence is what would break.
#[test]
fn the_scanner_finds_the_theme_reads_that_are_supposed_to_be_there() {
    let shadowing = shadowing_types();
    let mut inside = 0usize;
    let mut themed = 0usize;
    let mut themed_inside = 0usize;

    for path in qml_files() {
        let Ok(src) = fs::read_to_string(&path) else {
            continue;
        };
        for (_, access, shadowed) in accesses(&src, &shadowing) {
            if shadowed {
                inside += 1;
            }
            if access.split('.').any(|seg| seg == "theme") {
                themed += 1;
                if shadowed {
                    themed_inside += 1;
                }
            }
        }
    }

    assert!(
        inside > 20,
        "found only {inside} member accesses inside a Text or a Label across \
         qml/ - the scanner is not recognising those scopes, so its silence \
         about `style` means nothing"
    );
    assert!(themed > 0, "found no `theme` reads at all - see above");
    assert_eq!(
        themed,
        themed_inside,
        "{} of {themed} `theme` read(s) were placed outside a Text or a Label. \
         Either the scanner's scope tracking has drifted, or a `theme` read \
         has appeared where plain `style` would do and the alias is being \
         cargo-culted",
        themed - themed_inside
    );
}

#[test]
fn the_scanner_catches_the_shadowed_form() {
    let shadowing = shadowing_types();

    // Each of these is the mistake, in a shape the tree actually contains.
    for (what, src) in [
        (
            "a direct binding",
            r#"Item { Style { id: style } Text { color: style.textMuted } }"#,
        ),
        (
            "a grouped property",
            r#"Item { Style { id: style } Label { font.pixelSize: style.fontBody } }"#,
        ),
        (
            "nested below the text item",
            r#"Item { Text { MouseArea { onClicked: { foo(style.fontBody) } } } }"#,
        ),
        (
            "inside a template interpolation",
            "Item { Text { text: `a ${style.fontBody} b` } }",
        ),
    ] {
        let found = violations("Fixture.qml", src, &shadowing);
        assert_eq!(
            found.len(),
            1,
            "{what}: expected 1 violation, got {found:?}"
        );
    }
}

#[test]
fn the_scanner_does_not_cry_wolf() {
    let shadowing = shadowing_types();

    for (what, src) in [
        (
            "the palette read outside any text item",
            r#"Rectangle { Style { id: style } color: style.panelBg }"#,
        ),
        (
            "the theme alias, which is the fix",
            r#"Item { Text { color: root.theme.textMuted } }"#,
        ),
        (
            "a TextEdit, which carries no style property",
            r#"Item { TextEdit { color: style.textMuted } }"#,
        ),
        (
            "a comment naming the mistake",
            "Item { Text {\n    // Not style.fontBody: inside a Label that is the enum.\n    font.pixelSize: root.theme.fontBody\n} }",
        ),
        (
            "the words inside a string",
            r#"Item { Text { text: "write style.fontBody and it breaks" } }"#,
        ),
        (
            "a template literal body",
            "Item { Text { text: `write style.fontBody and it breaks` } }",
        ),
        (
            "a sibling that closed before the text item opened",
            r#"Item { Text { } Rectangle { color: style.panelBg } }"#,
        ),
    ] {
        let found = violations("Fixture.qml", src, &shadowing);
        assert!(found.is_empty(), "{what}: false positive {found:?}");
    }
}

/// An exemption without a reason is just a silenced test.
#[test]
fn every_text_style_exemption_is_argued() {
    for (key, reason) in EXEMPT {
        assert!(
            reason.len() > 60,
            "{key}: exemption reason is {} chars - argue why this read cannot \
             go through `theme`, or change it",
            reason.len()
        );
    }
}
