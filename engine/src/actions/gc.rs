use std::path::{Path, PathBuf};

use anyhow::Result;

use super::{Action, ActionInfo, ActionKind, ActionProvider, RunCommand, Urgency};
use crate::collector::Subject;

/// Store garbage collection, offered as four actions in order of how much
/// they destroy: survey, trim generations, free, then `-d`.
///
/// Offered always, at Routine urgency - the engine deliberately does NOT
/// compute the reclaimable size itself. `nix-collect-garbage --dry-run` walks
/// the whole store and takes seconds to minutes; running it on every request
/// would make a monitoring tool a source of load, which is self-defeating.
/// The walk is a thing you ask for, which is what the survey action is.
///
/// Splitting the survey out is what keeps it honest. It used to live inside
/// the deletion's `command` text - a dry-run on the first line, the real
/// thing on the last - while the Run button went straight to `-d`. So the
/// safe step was prose and the destructive step was a button, and reading
/// top-to-bottom disagreed with pressing Run about what would happen. No
/// wording fixed that while the asymmetry remained. Now each is a button, and
/// each `command` is the single line its own `run` performs.
///
/// That one-line equality is a property of these actions, not a general rule:
/// `command` is still documented as prose for a human, and the engine still
/// never executes it. See `RunCommand`.
///
/// **Why trimming and freeing are two buttons rather than one.** `-d` was the
/// only thing here that freed anything, and it deletes every old generation -
/// so the only offer that reclaimed space was also the one that destroyed
/// every rollback target. Keeping a couple of generations instead needs
/// `nix-env --delete-generations +N`, which `nix-collect-garbage` has no flag
/// for: its options are `-d`, `--delete-older-than`, `--max-freed` and
/// `--dry-run`, and none of them counts generations. Deleting generations
/// also frees nothing on its own - it removes gcroots, and a collection
/// afterwards is what reclaims the paths. Two steps is what the tools
/// actually are, and `run` is one program and argv with no shell, so it is
/// two buttons.
pub struct GarbageCollect;

/// How many generations the trim keeps: the one you are on, and one to go
/// back to.
const KEEP: usize = 2;

/// The point of the trim is that it is not `-d`. One generation is the one
/// being run, so KEEP has to leave a second or the action has no reason to
/// exist - checked here rather than in a test, because it cannot vary at run
/// time.
const _: () = assert!(KEEP >= 2);

/// The home-manager profile, if this machine has one.
///
/// Two layouts are live on real machines - the XDG path and the older
/// per-user one - and checking only the first would make the trim silently
/// absent rather than visibly wrong, which is harder to notice.
fn home_manager_profile() -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let mut candidates = vec![home.join(".local/state/nix/profiles/home-manager")];
    if let Some(user) = std::env::var_os("USER") {
        candidates.push(
            Path::new("/nix/var/nix/profiles/per-user")
                .join(user)
                .join("home-manager"),
        );
    }
    candidates.into_iter().find(|p| p.exists())
}

/// Whether a trim is worth offering. An offer that would delete nothing can
/// never be cleared, which is what 9b5030f went and removed from this list.
fn worth_trimming(count: usize) -> bool {
    count > KEEP
}

/// How many generations a profile has, by counting its `<name>-<n>-link`
/// siblings. A readdir, so it is cheap enough for every request.
fn generation_count(profile: &Path) -> usize {
    let Some(dir) = profile.parent() else {
        return 0;
    };
    let Some(stem) = profile.file_name().and_then(|n| n.to_str()) else {
        return 0;
    };
    let prefix = format!("{stem}-");

    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    entries
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_name()
                .to_str()
                .and_then(|n| n.strip_prefix(&prefix))
                .and_then(|rest| rest.strip_suffix("-link"))
                .is_some_and(|digits| digits.parse::<u64>().is_ok())
        })
        .count()
}

impl ActionProvider for GarbageCollect {
    fn id(&self) -> &'static str {
        "gc"
    }

    fn actions(&self) -> Result<Vec<Action>> {
        if !Path::new("/nix/store").is_dir() {
            return Ok(Vec::new());
        }

        // `report` sorts by urgency with a stable sort and all of these are
        // Routine, so this order is the order they appear in. It runs from
        // least to most destructive, and look-before-you-leap only reads that
        // way with the survey at the top.
        let mut out = vec![Action {
            id: "gc-store-survey".into(),
            title: "Survey what garbage collection would free".into(),
            subject: Subject::NixOS,
            kind: ActionKind::Shell,
            why: "How much a collection would reclaim is not measured here - \
                  finding out means walking the whole store, which is not \
                  something to do on a timer. This performs that walk once, \
                  when you ask, and deletes nothing."
                .into(),
            info: ActionInfo {
                what: "Runs the collection in dry-run mode: it reports what is \
                       unreachable and would be removed, and removes none of \
                       it. Elevated so it sees the system profile rather than \
                       only your own - the polkit prompt here buys scope, not \
                       destruction.",
                if_wrong: "The figure is a lower bound, not what -d would free. \
                           This surveys what is dead NOW, while the old \
                           generations are still gcroots holding their contents \
                           alive. -d discards those generations first, which \
                           makes more unreachable, so expect the real total to \
                           be larger than this says.",
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
        }];

        // Only offered when there is something to delete: a list that never
        // shrinks teaches you to stop reading it.
        if let Some(profile) = home_manager_profile() {
            let count = generation_count(&profile);
            if worth_trimming(count) {
                let path = profile.display().to_string();
                out.push(Action {
                    id: "gc-generations-keep".into(),
                    title: format!("Delete old home-manager generations, keeping the last {KEEP}"),
                    subject: Subject::NixOS,
                    kind: ActionKind::Shell,
                    why: format!(
                        "{count} have accumulated here - every home-manager \
                         switch adds one, and each is a gcroot, so a \
                         collection cannot reclaim anything they still \
                         reference. This keeps the newest {KEEP} and deletes \
                         the rest, which is what -d does too except that -d \
                         keeps none."
                    ),
                    info: ActionInfo {
                        what: "Deletes every generation of your own \
                               home-manager profile except the newest two. The \
                               +2 counts generations, not days.",
                        if_wrong: "It frees no space by itself - it removes the \
                                   gcroots, and the collection below reclaims \
                                   the paths. Rolling back further than two \
                                   generations stops being possible.",
                    },
                    command: format!("nix-env -p {path} --delete-generations +{KEEP}"),
                    run: Some(RunCommand {
                        program: "nix-env".into(),
                        args: vec![
                            "-p".into(),
                            path,
                            "--delete-generations".into(),
                            format!("+{KEEP}"),
                        ],
                        elevate: false,
                        cwd: None,
                    }),
                    effects: vec![
                        format!("Deletes {}, keeps the newest {KEEP}", count - KEEP),
                        "Frees no space on its own - collect afterwards".into(),
                        "No password: this is your own profile, not the system one".into(),
                    ],
                    needs_root: false,
                    urgency: Urgency::Routine,
                });
            }
        }

        out.push(Action {
            id: "gc-store-free".into(),
            title: "Free unreferenced paths, keeping every generation".into(),
            subject: Subject::NixOS,
            kind: ActionKind::Shell,
            why: "The collection without -d: it deletes what nothing \
                  references and leaves every generation standing. On its own \
                  it frees only what is already unrooted, so deleting old \
                  generations first is what gives it more to find."
                .into(),
            info: ActionInfo {
                what: "nix-collect-garbage with no flags, which is nix-store \
                       --gc: unreachable paths only. Profiles are gcroots, so \
                       whatever a surviving generation needs stays.",
                if_wrong: "It frees less than -d, deliberately. If it frees \
                           almost nothing, the store is still rooted by old \
                           generations - delete those first, then run it again.",
            },
            command: "sudo nix-collect-garbage".into(),
            run: Some(RunCommand {
                program: "nix-collect-garbage".into(),
                args: vec![],
                elevate: true,
                cwd: None,
            }),
            effects: vec![
                "Every generation survives, including the old ones".into(),
                "Deletes only what no generation references".into(),
                "Next rebuild may re-download what was deleted".into(),
            ],
            needs_root: true,
            urgency: Urgency::Routine,
        });

        out.push(Action {
            id: "gc-store".into(),
            title: "Collect garbage in the Nix store".into(),
            subject: Subject::NixOS,
            kind: ActionKind::Shell,
            why: "Old generations and unreferenced paths accumulate, and this \
                  deletes them. It is the destructive end of the set: the \
                  survey above does the same walk and removes nothing, and the \
                  two steps before it free space while leaving you something \
                  to roll back to."
                .into(),
            info: ActionInfo {
                what: "Deletes store paths nothing references any more. With -d \
                       it also deletes every old generation first, which is \
                       what makes their contents unreferenced.",
                if_wrong: "-d removes your rollback targets, in every profile \
                           it finds and not only the system one. Generations \
                           sharing a nixpkgs revision cost almost nothing, so \
                           most of what -d frees is build output a flagless \
                           collection frees without that cost.",
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
        });

        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generation_count_counts_only_numbered_links_of_that_profile() {
        let dir = std::env::temp_dir().join(format!("nixdash-gc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        for name in [
            "home-manager-1-link",
            "home-manager-2-link",
            "home-manager-51-link",
            // None of these count: no number, another profile, and the
            // current-generation symlink itself.
            "home-manager-link",
            "profile-7-link",
            "home-manager",
        ] {
            std::fs::write(dir.join(name), "").expect("write");
        }

        assert_eq!(generation_count(&dir.join("home-manager")), 3);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_trim_is_only_offered_when_it_would_delete_something() {
        // At or below KEEP there is nothing to delete, and an offer that
        // deletes nothing can never be cleared.
        for count in 0..=KEEP {
            assert!(!worth_trimming(count), "offered with {count} generations");
        }
        assert!(worth_trimming(KEEP + 1));
    }
}
