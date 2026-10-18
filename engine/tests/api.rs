use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use nixdash_engine::{router, Registry};
use serde_json::Value;
use tower::ServiceExt;

async fn get(registry: Registry, uri: &str) -> (StatusCode, Value) {
    let res = router(registry)
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap()
    };
    (status, body)
}

/// POST with no body - the run endpoint takes everything from the path.
///
/// Deliberately never posts to an action that would actually execute
/// something: these tests run on a real machine, and a test suite that
/// collects garbage or starts a rebuild would be a hazard, not a test.
async fn post(registry: Registry, uri: &str) -> (StatusCode, Value) {
    let res = router(registry)
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(uri)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap()
    };
    (status, body)
}

fn sampled() -> Registry {
    let r = Registry::with_default_collectors();
    r.tick_all();
    r
}

#[tokio::test]
async fn health_is_ok() {
    let (status, body) = get(Registry::with_default_collectors(), "/health").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "ok");
}

#[tokio::test]
async fn lists_both_default_panels() {
    let (status, body) = get(sampled(), "/api/panels").await;
    assert_eq!(status, StatusCode::OK);
    let ids: Vec<&str> = body["panels"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&"memory"), "got {ids:?}");
    assert!(ids.contains(&"failed-units"), "got {ids:?}");
}

#[tokio::test]
async fn memory_panel_has_a_real_reading() {
    let (status, body) = get(sampled(), "/api/panels/memory").await;
    assert_eq!(status, StatusCode::OK);
    let samples = body["samples"].as_array().unwrap();
    assert_eq!(samples.len(), 1);
    let v = &samples[0]["value"];
    assert!(v["total_kb"].as_u64().unwrap() > 0);
    assert!(v["available_kb"].as_u64().unwrap() > 0);
    assert!(samples[0]["at"].as_u64().unwrap() > 0);
}

#[tokio::test]
async fn history_respects_limit() {
    let r = sampled();
    for _ in 0..5 {
        r.tick_all();
    }
    let (_, body) = get(r, "/api/panels/memory?limit=3").await;
    assert_eq!(body["samples"].as_array().unwrap().len(), 3);
}

#[tokio::test]
async fn unknown_panel_is_404() {
    let (status, body) = get(sampled(), "/api/panels/nope").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(body["error"].as_str().unwrap().contains("nope"));
}

#[tokio::test]
async fn actions_endpoint_reports() {
    let (status, body) = get(sampled(), "/api/actions").await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["actions"].is_array(), "got {body}");
    assert!(body["errors"].is_array());

    // Every action must be self-describing: a command with no stated reason,
    // mechanism or consequences is exactly what this design exists to prevent.
    for a in body["actions"].as_array().unwrap() {
        let id = a["id"].as_str().unwrap();
        assert!(!a["title"].as_str().unwrap().is_empty());
        assert!(
            !a["why"].as_str().unwrap().is_empty(),
            "action {id} has no why"
        );
        assert!(!a["command"].as_str().unwrap().is_empty());
        assert!(
            !a["effects"].as_array().unwrap().is_empty(),
            "action {id} has no effects"
        );
        assert!(
            ["nixos", "qt", "rust"].contains(&a["subject"].as_str().unwrap_or("")),
            "action {id} has no valid subject"
        );
        assert!(
            ["shell", "nix"].contains(&a["kind"].as_str().unwrap_or("")),
            "action {id} has no valid kind"
        );
        for field in ["what", "if_wrong"] {
            let text = a["info"][field].as_str().unwrap_or("");
            assert!(
                text.len() > 30,
                "action {id}: info.{field} is {} chars - explain the mechanism \
                 and the risk, not the label",
                text.len()
            );
        }
    }
}

#[tokio::test]
async fn gc_action_is_always_offered_on_nixos() {
    let (_, body) = get(sampled(), "/api/actions").await;
    let ids: Vec<&str> = body["actions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| a["id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&"gc-store"), "got {ids:?}");
    assert!(ids.contains(&"gc-store-survey"), "got {ids:?}");

    // The survey must come first. Both are Routine and `report` sorts with a
    // stable sort, so provider order decides this - look-before-you-leap only
    // reads that way if the looking is above the leaping.
    let survey = ids.iter().position(|i| *i == "gc-store-survey").unwrap();
    let delete = ids.iter().position(|i| *i == "gc-store").unwrap();
    assert!(survey < delete, "survey must precede deletion, got {ids:?}");
}

/// The displayed command and the Run button must not disagree about risk.
///
/// This pair is the reason the split exists. The dry-run used to be the first
/// line of the deletion's `command` while Run went straight to `-d`, so the
/// safe-looking line sat directly above a destructive button. Each action now
/// shows the single line it actually performs, and this test fails if either
/// grows a second line or starts advertising the other's behaviour.
#[tokio::test]
async fn gc_commands_match_what_run_executes() {
    let (_, body) = get(sampled(), "/api/actions").await;
    let actions = body["actions"].as_array().unwrap();

    for (id, arg) in [("gc-store-survey", "--dry-run"), ("gc-store", "-d")] {
        let a = actions
            .iter()
            .find(|a| a["id"] == id)
            .unwrap_or_else(|| panic!("{id} not offered"));

        assert_eq!(a["run"]["program"], "nix-collect-garbage", "{id}");
        assert_eq!(a["run"]["args"], serde_json::json!([arg]), "{id}");

        // One line, so there is no second line for a reader to mistake for
        // the step that happens first.
        let command = a["command"].as_str().unwrap();
        assert_eq!(
            command,
            format!("sudo nix-collect-garbage {arg}"),
            "{id} command drifted from its argv"
        );
    }

    // The destructive half must never again advertise a survey it does not do.
    let delete = actions.iter().find(|a| a["id"] == "gc-store").unwrap();
    assert!(
        !delete["command"].as_str().unwrap().contains("--dry-run"),
        "the deletion's command must not contain a dry-run"
    );

    // ...and the survey must never grow the flag that deletes.
    let survey = actions
        .iter()
        .find(|a| a["id"] == "gc-store-survey")
        .unwrap();
    assert!(
        !survey["run"]["args"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a == "-d"),
        "the survey must not pass -d"
    );
}

/// The engine must never grow a way to execute what it suggests.
#[tokio::test]
async fn unknown_actions_cannot_be_run() {
    // Actions are derived from live state, so ids come and go. An id that is
    // not currently offered must not be executable by any route.
    let (status, _) = post(sampled(), "/api/actions/no-such-action/run").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn the_run_endpoint_takes_no_command_from_the_caller() {
    // There is exactly one way in: name an action. If a caller could ever
    // smuggle a program or an argument through the URL, the fixed set of
    // things the engine can execute would stop being fixed.
    for uri in [
        "/api/actions/run",
        "/api/actions/gc-store;id/run",
        "/api/actions/..%2F..%2Fbin%2Fsh/run",
    ] {
        let (status, _) = post(sampled(), uri).await;
        assert!(
            status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED,
            "{uri} returned {status}"
        );
    }
}

/// Nix snippets are configuration, not commands.
///
/// Running one would be nonsense, and the failure has to be explicit rather
/// than the engine improvising something from the snippet text.
#[tokio::test]
async fn nix_snippets_are_offered_but_not_runnable() {
    let (_, body) = get(sampled(), "/api/actions").await;
    let actions = body["actions"].as_array().unwrap();

    let mut checked = 0;
    for a in actions {
        if a["kind"] != "nix" {
            continue;
        }
        assert!(
            a["run"].is_null(),
            "{} is a nix snippet but carries a run command",
            a["id"]
        );
        let id = a["id"].as_str().unwrap();
        let (status, body) = post(sampled(), &format!("/api/actions/{id}/run")).await;
        assert_eq!(
            status,
            StatusCode::UNPROCESSABLE_ENTITY,
            "{id} should refuse to run, got {status}"
        );
        assert!(body["error"].as_str().unwrap().contains("not something"));
        checked += 1;
    }
    // The qt/rust providers are conditional on this machine's state, so an
    // empty run is possible - say so rather than passing silently.
    eprintln!("checked {checked} nix actions");
}

/// The thing that gets executed is never the thing that gets displayed.
///
/// `command` is prose for a human: multi-line, commented, often leading with a
/// dry-run or an inspection step. Executing it would run the commentary and
/// the alternatives along with the real thing. This test pins the separation
/// so a later "simplification" that parses `command` fails loudly.
#[tokio::test]
async fn executable_commands_are_explicit_never_parsed_from_display_text() {
    let (_, body) = get(sampled(), "/api/actions").await;

    for a in body["actions"].as_array().unwrap() {
        let Some(run) = a["run"].as_object() else {
            continue;
        };
        let id = a["id"].as_str().unwrap();
        let program = run["program"].as_str().unwrap();

        assert!(!program.is_empty(), "{id}: empty program");
        // A program name, not a command line. Any of these would mean the
        // display text had leaked into the execution path.
        for bad in [' ', '\n', ';', '|', '&', '#'] {
            assert!(
                !program.contains(bad),
                "{id}: program {program:?} contains {bad:?} - it must be one \
                 executable, not a shell line"
            );
        }
        // Escalation is pkexec's job, decided by `elevate`. An embedded sudo
        // would want a tty this service does not have, and would hang.
        assert_ne!(program, "sudo", "{id}: escalation must go through elevate");
        assert!(
            !run["args"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v.as_str() == Some("sudo")),
            "{id}: sudo in args"
        );

        // needs_root is what the UI shows; elevate is what actually happens.
        // If they disagree the UI is lying about whether you will be prompted.
        assert_eq!(
            a["needs_root"].as_bool().unwrap(),
            run["elevate"].as_bool().unwrap(),
            "{id}: needs_root disagrees with run.elevate"
        );
    }
}

/// Every panel, and every field it emits, must carry an explanation.
///
/// This is the `rn` rule - "adding a control, a stat or an automation step
/// means adding its info panel in the same change, not as a follow-up task" -
/// made enforceable. Without a test it decays the first time someone is in a
/// hurry, and the explanations are the product, not decoration.
#[tokio::test]
async fn headlines_claim_only_what_was_measured() {
    // The Qt panel once reported "no Qt in this environment" when it found no
    // qmake - while being rendered by libQt6Qml, inside an app built with the
    // very toolchain it was declaring absent. The Rust panel said the same
    // thing about a compiled Rust binary.
    //
    // Both panels answer "could you BUILD here?", and the only thing either
    // looks at is a build tool on PATH. Runtime libraries come from a
    // binary's own Nix closure by RPATH and are never consulted. A headline
    // that generalises a missing tool into a missing technology is not a
    // wording nit: it teaches the reader a wrong model of how Nix resolves
    // things, in an app whose whole purpose is explaining this machine.
    let (_, body) = get(sampled(), "/api/panels").await;

    for panel in body["panels"].as_array().unwrap() {
        let id = panel["id"].as_str().unwrap();
        let headline = panel["headline"].as_str().unwrap_or("");
        for claim in ["no qt", "no rust", "qt is not", "rust is not"] {
            assert!(
                !claims_absence_of(headline, claim),
                "panel {id} headline {headline:?} claims {claim:?}. Say which \
                 TOOL or artefact is missing (qmake, rustc, the desktop UI) - \
                 absence of a build tool is not absence of the technology."
            );
        }
    }
}

/// The same rule, applied to the verdicts the UI composes for itself.
///
/// `headlines_claim_only_what_was_measured` greps the API payload, so it sees
/// every headline the engine produces and none of the ones QML builds. Both
/// the Qt and Rust panels build theirs locally - `QtPanel.verdict` and the
/// bold line at the top of `RustPanel` - which puts the two most prominent
/// claims in the app outside the test written to govern exactly them.
///
/// Reads `../qml` as data, like qml_info.rs, and shares `claims_absence_of`
/// with the API test on purpose: one definition of the rule, or the two
/// corpora drift into disagreeing about what the rule is.
///
/// Scoped to `text:` and `verdict:`. The explanation fields are prose ABOUT
/// claims and legitimately quote the wrong ones - "'No qmake on PATH' does
/// NOT mean Qt is absent" has to be sayable.
#[test]
fn qml_verdicts_claim_only_what_was_measured() {
    let qml = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("engine/ has a parent")
        .join("qml");

    let mut checked = 0usize;
    let mut failures = Vec::new();

    for entry in std::fs::read_dir(&qml).expect("qml/ is readable").flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("qml") {
            continue;
        }
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let text = std::fs::read_to_string(&path).unwrap_or_default();

        for (n, line) in text.lines().enumerate() {
            let t = line.trim_start();
            if !(t.starts_with("text:") || t.starts_with("verdict:")) {
                continue;
            }
            // Only the literals on this line; a wrapped ternary continues
            // below and is caught on its own line.
            for lit in line.split('"').skip(1).step_by(2) {
                checked += 1;
                for claim in ["no qt", "no rust", "qt is not", "rust is not"] {
                    if claims_absence_of(lit, claim) {
                        failures.push(format!(
                            "{name}:{} - verdict {lit:?} claims {claim:?}. Name the \
                             TOOL that is missing (qmake, rustc), not the \
                             technology: absence of a build tool is not absence \
                             of the technology, and this is the most visible \
                             line in the panel.",
                            n + 1
                        ));
                    }
                }
            }
        }
    }

    assert!(
        checked > 20,
        "matched only {checked} verdict literals - scanner broken"
    );
    assert!(
        failures.is_empty(),
        "{} of {checked} UI verdicts overclaim:\n\n{}",
        failures.len(),
        failures.join("\n\n")
    );
}

/// The matcher has now been wrong in both directions - too loose, then too
/// strict - so its own behaviour is pinned rather than left to be rediscovered
/// the next time a headline is reworded.
#[test]
fn the_headline_matcher_distinguishes_a_claim_from_a_name() {
    // Forbidden: generalising to the technology.
    for bad in [
        "no qt in this environment",
        "no rust in this environment",
        "no qt.",
        "there is no rust",
    ] {
        let claim = if bad.contains("qt") {
            "no qt"
        } else {
            "no rust"
        };
        assert!(claims_absence_of(bad, claim), "should be rejected: {bad:?}");
    }
    // Allowed: naming the specific thing that is missing.
    for good in [
        "no qmake on PATH - cannot tell whether a Qt build would work",
        "no rustc on PATH - cannot tell whether a Rust build would work",
        "1.95.0 · rust-analyzer cannot resolve std (no rust-src)",
        "the desktop UI is not installed - nothing to inspect",
    ] {
        for claim in ["no qt", "no rust"] {
            assert!(
                !claims_absence_of(good, claim),
                "should be accepted: {good:?} (tripped on {claim:?})"
            );
        }
    }
}

/// Does `headline` make `claim` as a whole phrase?
///
/// Whole-word matching, not `contains`. A plain substring test rejects "no
/// rustc on PATH" for containing "no rust" - a precise, correct headline
/// failing the rule it actually satisfies. That very nearly shipped: the
/// branch is only reached on a machine without rustc, which is neither this
/// one nor the Nix build sandbox, so no amount of running the suite here
/// would have found it.
fn claims_absence_of(headline: &str, claim: &str) -> bool {
    let lower = headline.to_lowercase();
    let mut from = 0;
    while let Some(idx) = lower[from..].find(claim) {
        let start = from + idx;
        let end = start + claim.len();
        // The character after the match decides it: "no qt." or "no qt " is
        // the forbidden claim, while "no rustc", "no rust-src" and
        // "no qt-env" all name a specific thing. Hyphens and underscores
        // continue a token - package and component names are full of them,
        // and treating "no rust-src" as the claim "no rust" would reject the
        // most precise wording available.
        let continues = lower[end..]
            .chars()
            .next()
            .is_some_and(|c| c.is_alphanumeric() || c == '-' || c == '_');
        if !continues {
            return true;
        }
        from = end;
    }
    false
}

#[tokio::test]
async fn every_panel_and_stat_is_explained() {
    let (_, body) = get(sampled(), "/api/panels").await;

    for panel in body["panels"].as_array().unwrap() {
        let id = panel["id"].as_str().unwrap();

        for field in ["what", "why", "if_wrong"] {
            let text = panel["info"][field].as_str().unwrap_or("");
            assert!(!text.is_empty(), "panel {id}: info.{field} is empty");
            // A label restated is not an explanation. Short text is the shape
            // "Shows memory usage" takes, so it is worth failing on.
            assert!(
                text.len() > 30,
                "panel {id}: info.{field} is {} chars - explain the mechanism, \
                 not the label",
                text.len()
            );
        }

        let documented: Vec<&str> = panel["stats"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["key"].as_str().unwrap())
            .collect();

        for s in panel["stats"].as_array().unwrap() {
            let key = s["key"].as_str().unwrap();
            for field in ["what", "why", "if_wrong"] {
                let text = s[field].as_str().unwrap_or("");
                assert!(!text.is_empty(), "panel {id}, stat {key}: {field} is empty");
            }
        }

        // Every key the collector actually emits needs an entry. Catches
        // adding a field without explaining it, which is the usual way this
        // rots.
        if let Some(value) = panel["latest"]["value"].as_object() {
            for key in value.keys() {
                assert!(
                    documented.contains(&key.as_str()),
                    "panel {id}: emits '{key}' with no stat info - add one in \
                     the same change"
                );
            }
        }
    }
}
