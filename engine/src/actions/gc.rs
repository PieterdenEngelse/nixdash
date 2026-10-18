use anyhow::Result;

use super::{Action, ActionInfo, ActionKind, ActionProvider, RunCommand, Urgency};
use crate::collector::Subject;

/// Store garbage collection, offered as two actions: the survey, then the
/// deletion.
///
/// Offered always, at Routine urgency - the engine deliberately does NOT
/// compute the reclaimable size itself. `nix-collect-garbage --dry-run` walks
/// the whole store and takes seconds to minutes; running it on every request
/// would make a monitoring tool a source of load, which is self-defeating.
/// The walk is a thing you ask for, which is what the survey action is.
///
/// Splitting the pair is what keeps the survey honest. It used to live inside
/// the deletion's `command` text - a dry-run on the first line, the real
/// thing on the last - while the Run button went straight to `-d`. So the
/// safe step was prose and the destructive step was a button, and reading
/// top-to-bottom disagreed with pressing Run about what would happen. No
/// wording fixed that while the asymmetry remained. Now each is a button, and
/// each `command` is the single line its own `run` performs.
///
/// That one-line equality is a property of these two actions, not a general
/// rule: `command` is still documented as prose for a human, and the engine
/// still never executes it. See `RunCommand`.
pub struct GarbageCollect;

impl ActionProvider for GarbageCollect {
    fn id(&self) -> &'static str {
        "gc"
    }

    fn actions(&self) -> Result<Vec<Action>> {
        if !std::path::Path::new("/nix/store").is_dir() {
            return Ok(Vec::new());
        }

        // Survey first: `report` sorts by urgency with a stable sort, and both
        // of these are Routine, so this order is the order they appear in.
        // Look-before-you-leap reads correctly only in that order.
        Ok(vec![
            Action {
                id: "gc-store-survey".into(),
                title: "Survey what garbage collection would free".into(),
                subject: Subject::NixOS,
                kind: ActionKind::Shell,
                why: "How much a collection would reclaim is not measured \
                      here - finding out means walking the whole store, which \
                      is not something to do on a timer. This performs that \
                      walk once, when you ask, and deletes nothing."
                    .into(),
                info: ActionInfo {
                    what: "Runs the collection in dry-run mode: it reports \
                           what is unreachable and would be removed, and \
                           removes none of it. Elevated so it sees the system \
                           profile rather than only your own - the polkit \
                           prompt here buys scope, not destruction.",
                    if_wrong: "The figure is a lower bound, not what -d would \
                               free. This surveys what is dead NOW, while the \
                               old generations are still gcroots holding their \
                               contents alive. -d discards those generations \
                               first, which makes more unreachable, so expect \
                               the real total to be larger than this says.",
                },
                command: "sudo nix-collect-garbage --dry-run".into(),
                run: Some(RunCommand {
                    program: "nix-collect-garbage".into(),
                    args: vec!["--dry-run".into()],
                    elevate: true,
                    cwd: None,
                }),
                effects: vec![
                    "Deletes nothing - this is the survey".into(),
                    "Walks the whole store, so it takes seconds to minutes".into(),
                ],
                needs_root: true,
                urgency: Urgency::Routine,
            },
            Action {
                id: "gc-store".into(),
                title: "Collect garbage in the Nix store".into(),
                subject: Subject::NixOS,
                kind: ActionKind::Shell,
                why: "Old generations and unreferenced paths accumulate, and \
                      this deletes them. It is the destructive half of the \
                      pair: the survey above does the same walk and removes \
                      nothing, if you want the figure before committing."
                    .into(),
                info: ActionInfo {
                    what: "Deletes store paths nothing references any more. \
                           With -d it also deletes every old generation first, \
                           which is what makes their contents unreferenced.",
                    if_wrong: "-d removes your rollback targets. Generations \
                               sharing a nixpkgs revision cost almost nothing, \
                               so most of what -d frees is build output you \
                               would free anyway - survey first and look \
                               before deciding it is worth losing them.",
                },
                command: "sudo nix-collect-garbage -d".into(),
                run: Some(RunCommand {
                    program: "nix-collect-garbage".into(),
                    args: vec!["-d".into()],
                    elevate: true,
                    cwd: None,
                }),
                effects: vec![
                    "-d deletes ALL old generations - rollback targets disappear".into(),
                    "Anything not reachable from a gcroot is removed".into(),
                    "Next rebuild may re-download what was deleted".into(),
                ],
                needs_root: true,
                urgency: Urgency::Routine,
            },
        ])
    }
}
