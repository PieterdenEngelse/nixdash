use axum::{
    extract::{Path, Query, State},
    http::{HeaderValue, Method, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tower_http::{
    cors::{AllowOrigin, CorsLayer},
    trace::TraceLayer,
};

use std::sync::{Arc, Mutex};

use crate::{actions::Actions, builds, registry::Registry};

/// Router state: panels to read, actions to suggest and run.
#[derive(Clone)]
pub struct AppState {
    pub registry: Registry,
    pub actions: Actions,
    /// The port actually bound, so the settings endpoint can report what is
    /// live alongside what is declared.
    pub port: u16,
    /// The dev engine this service started, if it started one.
    ///
    /// Only ever used to answer "can we stop it", never to answer "is it
    /// running" - that is a probe. A remembered pid does not survive a
    /// restart of this service, and a dev engine does, so believing the pid
    /// would report a running engine as stopped.
    pub dev_engine: Arc<Mutex<Option<u32>>>,
}

pub fn router(registry: Registry) -> Router {
    router_with(AppState {
        registry,
        actions: Actions::with_defaults(),
        port: std::env::var("NIXDASH_PORT")
            .ok()
            .and_then(|p| p.parse().ok())
            .unwrap_or(3100),
        dev_engine: Arc::new(Mutex::new(None)),
    })
}

/// Is this origin one of our own loopback UIs?
///
/// This used to be `CorsLayer::permissive()`, which was harmless while every
/// route was a GET of read-only data. It is not harmless now: with a POST that
/// can start a privileged action, permissive CORS means any page in the
/// browser - any site, not just ours - can ask the engine to begin a rebuild
/// and raise a polkit prompt the user did not go looking for. A prompt you did
/// not expect is a prompt you might click through.
///
/// Binding to loopback does not help here: the request comes *from* the
/// browser, which is on loopback. So the origin has to be checked. Our wasm UI
/// is served from a static server on another port, so an exact origin will not
/// do - any loopback port, but only loopback.
fn is_loopback_origin(origin: &HeaderValue) -> bool {
    let Ok(origin) = origin.to_str() else {
        return false;
    };
    let Some(rest) = origin
        .strip_prefix("http://")
        .or_else(|| origin.strip_prefix("https://"))
    else {
        return false;
    };
    // Split the port off, taking care with the bracketed IPv6 form.
    let host = match rest.strip_prefix('[') {
        Some(after) => match after.split_once(']') {
            Some((h, _port)) => h,
            None => return false,
        },
        None => rest.split(':').next().unwrap_or(""),
    };
    matches!(host, "localhost" | "127.0.0.1" | "::1")
}

pub fn router_with(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::predicate(|origin, _req| {
            is_loopback_origin(origin)
        }))
        .allow_methods([Method::GET, Method::POST])
        .allow_headers([axum::http::header::CONTENT_TYPE]);

    Router::new()
        .route("/health", get(health))
        .route("/api/panels", get(list_panels))
        .route("/api/actions", get(list_actions))
        // axum 0.8 path params are {id}, not :id
        .route("/api/panels/{id}", get(panel_history))
        .route("/api/actions/{id}/run", post(run_action))
        .route("/api/builds", get(list_builds))
        .route("/api/builds/{id}/run", post(run_build))
        .route("/api/builds/{id}/stop", post(stop_build))
        .route("/api/settings", get(list_settings).post(write_setting))
        .route("/api/settings/preview", post(preview_setting))
        .route("/api/justfile", get(read_justfile))
        .route("/api/devshell", get(list_devshell).post(toggle_devshell))
        .route("/api/system", get(list_system).post(toggle_system))
        .layer(TraceLayer::new_for_http())
        .layer(cors)
        .with_state(state)
}

/// Liveness, and *which build* is answering.
///
/// `version` is the crate version, which a solo project bumps rarely enough
/// that it cannot tell two builds apart. `built` can: it is baked in at
/// compile time, so a reply from a binary that has been running since before
/// your last rebuild says so instead of looking identical to a fresh one.
async fn health() -> Json<serde_json::Value> {
    Json(json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "built": env!("NIXDASH_BUILT"),
        "built_at": env!("NIXDASH_BUILT_AT").parse::<u64>().ok(),
    }))
}

async fn list_panels(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "panels": state.registry.summaries() }))
}

async fn list_actions(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(serde_json::to_value(state.actions.report()).unwrap_or_else(|_| json!({})))
}

/// Execute one suggested action.
///
/// The action is looked up by id and its *own* `RunCommand` is executed. The
/// request body is ignored entirely - the caller names which action to run and
/// nothing else. It cannot supply a program, an argument, or a flag. That is
/// the one property worth protecting here: the set of things this endpoint can
/// ever execute is the set of actions the providers decided to offer, and it is
/// fixed at compile time.
///
/// Root, where needed, comes from pkexec: polkit prompts, and the prompt is
/// the authorisation. The engine has no privilege to lend.
async fn run_action(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let report = state.actions.report();
    let action = report
        .actions
        .into_iter()
        .find(|a| a.id == id)
        // Actions are derived from live state, so an id can legitimately
        // disappear between listing and running - the unit recovered, the
        // rebuild already happened. That is a 404, not an error.
        .ok_or_else(|| ApiError::NotFound(format!("no action {id}")))?;

    let Some(command) = action.run.clone() else {
        return Err(ApiError::NotRunnable(format!(
            "{id} is not something that can be run: it is configuration to \
             apply, not a command to execute"
        )));
    };

    // spawn_blocking, because `run` blocks the thread for as long as the
    // command takes - and `nixos-rebuild switch` takes minutes. On a tokio
    // worker that would stall every other request, including the polling the
    // UI does to stay current.
    let outcome = tokio::task::spawn_blocking(move || crate::actions::runner::run(&command))
        .await
        .map_err(|e| ApiError::Internal(format!("run task failed: {e}")))?;

    Ok(Json(json!({
        "action": action.id,
        "title": action.title,
        "outcome": outcome,
        "ok": outcome.succeeded(),
    })))
}

/// State of the Dev page's build lines.
///
/// Only the dev engine has a state to report; the rest are commands that run
/// and finish, and inventing a state for them would be a reading the app
/// never took.
async fn list_builds(State(state): State<AppState>) -> Json<Value> {
    let ours = *state.dev_engine.lock().expect("dev_engine mutex");
    let dev = tokio::task::spawn_blocking(move || builds::probe(ours.is_some()))
        .await
        .unwrap_or(builds::DevEngine::Stopped);
    Json(json!({
        "builds": builds::all().iter().map(|b| json!({
            "id": b.id,
            "label": b.label,
            "daemon": matches!(b.execution, builds::Execution::Daemon(_)),
        })).collect::<Vec<_>>(),
        "dev_engine": dev,
        "dev_port": builds::DEV_PORT,
    }))
}

/// Run one build line.
///
/// Takes no body, exactly like the actions endpoint: the caller names an entry
/// from a compile-time list, so nothing a request can say widens what is
/// executable.
async fn run_build(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let build = builds::find(&id).ok_or_else(|| ApiError::NotFound(format!("no build {id}")))?;

    match build.execution {
        builds::Execution::Wait(cmd) => {
            // Same reasoning as run_action: these block a thread for minutes.
            let outcome = tokio::task::spawn_blocking(move || crate::actions::runner::run(&cmd))
                .await
                .map_err(|e| ApiError::Internal(format!("run task failed: {e}")))?;
            Ok(Json(json!({
                "build": build.id,
                "label": build.label,
                "outcome": outcome,
                "ok": outcome.succeeded(),
            })))
        }
        // A window, started and let go. Deliberately no probe and no claim
        // about what is on screen: whether a window is actually drawn is a
        // reading only the person at the keyboard can take.
        builds::Execution::Detach(cmd) => {
            let log = std::env::temp_dir().join("nixdash-window.log");
            let spawned = tokio::task::spawn_blocking(move || {
                crate::actions::runner::spawn_detached(&cmd, &log, &[])
            })
            .await
            .map_err(|e| ApiError::Internal(format!("spawn task failed: {e}")))?;

            let ok = spawned.still_running();
            let detail = if ok {
                "started - if no window appears, its reason is in the log".to_string()
            } else if let Some(code) = spawned.exited {
                format!("exited at once (status {code}) - see {}", spawned.log)
            } else {
                format!("nothing started - see {}", spawned.log)
            };
            Ok(Json(json!({
                "build": build.id,
                "label": build.label,
                "ok": ok,
                "spawn": spawned,
                "detail": detail,
            })))
        }
        // A window started, then the older ones closed - in that order.
        builds::Execution::Replace(cmd) => {
            // Collected BEFORE the spawn so the new window is never in the
            // list of things to close.
            let previous = tokio::task::spawn_blocking(builds::window_pids)
                .await
                .unwrap_or_default();

            let log = std::env::temp_dir().join("nixdash-window.log");
            let spawned = tokio::task::spawn_blocking(move || {
                crate::actions::runner::spawn_detached(&cmd, &log, &[])
            })
            .await
            .map_err(|e| ApiError::Internal(format!("spawn task failed: {e}")))?;

            // One judgement, taken by the spawner, which watched the
            // process rather than asking /proc whether a pid exists. The
            // earlier version asked /proc, a zombie answered yes, and two
            // real windows were closed for a start that never happened.
            if !spawned.still_running() {
                let detail = match spawned.exited {
                    Some(code) => format!(
                        "the new window exited at once (status {code}) - nothing was \
                         closed; see {}",
                        spawned.log
                    ),
                    None => format!(
                        "nothing started, so nothing was closed; see {}",
                        spawned.log
                    ),
                };
                return Ok(Json(json!({
                    "build": build.id,
                    "label": build.label,
                    "ok": false,
                    "spawn": spawned,
                    "closed": 0,
                    "detail": detail,
                })));
            }
            let pid = spawned.pid.unwrap_or(0);

            let closed = tokio::task::spawn_blocking(move || builds::close_windows(&previous))
                .await
                .unwrap_or(0);

            Ok(Json(json!({
                "build": build.id,
                "label": build.label,
                "ok": true,
                "spawn": spawned,
                "closed": closed,
                // Whoever pressed this is very likely one of the windows that
                // just closed, so this reply may have nowhere to be read.
                "detail": format!("started pid {pid}, closed {closed} older window(s)"),
            })))
        }
        builds::Execution::Daemon(cmd) => {
            // Refuse rather than start a second one. Two engines on one port
            // means the loser dies instantly and the survivor is whichever
            // got there first, which is not something to report as a start.
            // `ours` from the recorded pid, not a constant: this app may
            // have started the thing already holding the port, and reporting
            // that as someone else's would send you looking for a terminal
            // that does not exist.
            let owned = state.dev_engine.lock().expect("dev_engine mutex").is_some();
            let before = tokio::task::spawn_blocking(move || builds::probe(owned))
                .await
                .unwrap_or(builds::DevEngine::Stopped);
            if before != builds::DevEngine::Stopped {
                return Ok(Json(json!({
                    "build": build.id,
                    "label": build.label,
                    "ok": false,
                    "state": before,
                    "detail": format!(
                        "port {} is already taken - nothing was started",
                        builds::DEV_PORT
                    ),
                })));
            }

            let log = std::env::temp_dir().join("nixdash-dev-engine.log");
            let port = builds::DEV_PORT.to_string();
            let spawned = tokio::task::spawn_blocking(move || {
                crate::actions::runner::spawn_detached(&cmd, &log, &[("NIXDASH_PORT", port)])
            })
            .await
            .map_err(|e| ApiError::Internal(format!("spawn task failed: {e}")))?;

            if let Some(pid) = spawned.pid {
                *state.dev_engine.lock().expect("dev_engine mutex") = Some(pid);
            }

            // The fork succeeding says nothing about the server being up, so
            // ask the port. Retried briefly because binding is not instant,
            // and a single immediate probe would report every healthy start
            // as a failure.
            let after = tokio::task::spawn_blocking(|| {
                for _ in 0..20 {
                    let seen = builds::probe(true);
                    if seen != builds::DevEngine::Stopped {
                        return seen;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(150));
                }
                builds::DevEngine::Stopped
            })
            .await
            .unwrap_or(builds::DevEngine::Stopped);

            let started = matches!(after, builds::DevEngine::Running { .. });
            Ok(Json(json!({
                "build": build.id,
                "label": build.label,
                "ok": started && spawned.error.is_none(),
                "spawn": spawned,
                "state": after,
                // Named whether it worked or not: when it did not, this file
                // is the only place the reason exists.
                "detail": if started {
                    format!("answering on {}", builds::DEV_PORT)
                } else {
                    format!(
                        "started nothing that answers on {} - see {}",
                        builds::DEV_PORT, spawned.log
                    )
                },
            })))
        }
    }
}

/// Stop the dev engine, if this service is the one that started it.
async fn stop_build(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let build = builds::find(&id).ok_or_else(|| ApiError::NotFound(format!("no build {id}")))?;
    if !matches!(build.execution, builds::Execution::Daemon(_)) {
        return Err(ApiError::NotRunnable(format!(
            "{id} runs and finishes - there is nothing to stop"
        )));
    }

    let pid = *state.dev_engine.lock().expect("dev_engine mutex");
    let Some(pid) = pid else {
        // No pid is two different situations and they get two different
        // answers. Collapsing them would report an idle port as a refusal,
        // which is the "nothing found versus could not look" mistake.
        let seen = tokio::task::spawn_blocking(|| builds::probe(false))
            .await
            .unwrap_or(builds::DevEngine::Stopped);
        if seen == builds::DevEngine::Stopped {
            return Ok(Json(json!({
                "build": build.id,
                "ok": true,
                "detail": format!("nothing is listening on {}", builds::DEV_PORT),
            })));
        }
        // Something IS there, and it is not ours. Deliberately not a
        // kill-by-name: killing a process this app cannot account for is
        // worse than declining and saying why.
        return Err(ApiError::NotRunnable(format!(
            "something is on {} that this app did not start, so it will not \
             stop it - use the terminal it was started from",
            builds::DEV_PORT
        )));
    };

    match tokio::task::spawn_blocking(move || crate::actions::runner::stop(pid))
        .await
        .map_err(|e| ApiError::Internal(format!("stop task failed: {e}")))?
    {
        Ok(()) => {
            *state.dev_engine.lock().expect("dev_engine mutex") = None;
            Ok(Json(
                json!({ "build": build.id, "ok": true, "stopped": pid }),
            ))
        }
        Err(e) => Err(ApiError::Internal(e)),
    }
}

/// A request to change one setting.
///
/// Note the contrast with the run endpoint, which deliberately takes **no**
/// body at all. The difference is what the body can express: there, a body
/// would widen the set of executable things beyond what the providers offer;
/// here it names one key from a fixed list and a value that is range- or
/// enum-checked before anything is written. The surface stays closed either
/// way - this one just needs two words instead of one.
#[derive(Debug, Deserialize)]
pub struct SettingChange {
    key: String,
    value: crate::settings::SettingValue,
}

fn settings_file() -> Result<(std::path::PathBuf, String), ApiError> {
    let path = crate::settings::settings_path()
        .ok_or_else(|| ApiError::Internal("no HOME, cannot locate settings".into()))?;
    // Absent is normal - nothing has been changed from the app yet - and must
    // read as an empty declaration rather than an error.
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    Ok((path, text))
}

/// Every setting the app may change, with what is declared and what is live.
///
/// Both are reported because on a declarative system they are genuinely two
/// different facts, and the gap between them is the thing worth seeing: a
/// value written here does nothing until the next `home-manager switch`.
async fn list_settings(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let (path, text) = settings_file()?;
    let declared = crate::settings::read_declared(&text);

    let effective = json!({
        "port": state.port,
        "logLevel": std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()),
    });

    let settings: Vec<serde_json::Value> = crate::settings::known()
        .into_iter()
        .map(|s| {
            let value = declared
                .iter()
                .find(|(k, _)| *k == s.key)
                .map(|(_, v)| serde_json::to_value(v).unwrap_or(Value::Null))
                .unwrap_or(Value::Null);
            let mut obj = serde_json::to_value(&s).unwrap_or_else(|_| json!({}));
            if let Some(map) = obj.as_object_mut() {
                map.insert("declared".into(), value);
            }
            obj
        })
        .collect();

    Ok(Json(json!({
        "path": path.display().to_string(),
        "exists": path.exists(),
        "settings": settings,
        "effective": effective,
    })))
}

/// What a change would do, without doing it.
async fn preview_setting(
    Json(change): Json<SettingChange>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let (path, text) = settings_file()?;
    let plan = crate::settings::plan(
        &text,
        &path.display().to_string(),
        &change.key,
        &change.value,
    )
    .map_err(|e| ApiError::NotRunnable(e.to_string()))?;
    Ok(Json(
        serde_json::to_value(plan).unwrap_or_else(|_| json!({})),
    ))
}

/// Write one setting.
///
/// Writes the single file the engine owns, regenerated whole. It does not
/// rebuild: the response says what still has to happen, because on this
/// system writing Nix source and applying it are separate acts and conflating
/// them would be the lie this page exists to avoid.
async fn write_setting(
    Json(change): Json<SettingChange>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let (path, text) = settings_file()?;
    let plan = crate::settings::plan(
        &text,
        &path.display().to_string(),
        &change.key,
        &change.value,
    )
    .map_err(|e| ApiError::NotRunnable(e.to_string()))?;

    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| ApiError::Internal(format!("creating {}: {e}", dir.display())))?;
    }
    std::fs::write(&path, &plan.rendered)
        .map_err(|e| ApiError::Internal(format!("writing {}: {e}", path.display())))?;

    tracing::info!(key = %plan.key, path = %path.display(), "wrote setting");

    Ok(Json(json!({
        "written": true,
        "path": path.display().to_string(),
        "key": plan.key,
        "from": plan.from,
        "to": plan.to,
        "diff": plan.diff,
        "applied": false,
        "next_step": "Run `home-manager switch`, then restart the engine. \
                      Nothing has changed yet - this only edited Nix source.",
    })))
}

#[derive(Debug, Deserialize)]
pub struct DevshellToggle {
    key: String,
    enabled: bool,
}

/// The project's `Justfile`, as it is on disk right now.
///
/// Read at request time rather than compiled in. The Commands board shows
/// these recipes and a test checks the board against them, so the one thing
/// this must not do is hand back a copy that was true when the service was
/// built - that is the drift the board exists to catch, reintroduced one
/// layer down.
///
/// A read that fails is reported as a failure, with the path and the reason.
/// The file being absent and the file being unreadable are both "could not
/// look", and neither is an empty Justfile.
async fn read_justfile() -> Result<Json<serde_json::Value>, ApiError> {
    let path = crate::builds::repo().join("Justfile");
    let text = std::fs::read_to_string(&path)
        .map_err(|e| ApiError::NotFound(format!("cannot read {}: {e}", path.display())))?;
    Ok(Json(serde_json::json!({
        "path": path.display().to_string(),
        "text": text,
    })))
}

fn devshell_file() -> Result<(std::path::PathBuf, String), ApiError> {
    let path = crate::devshell::extras_path()
        .ok_or_else(|| ApiError::NotFound("no project directory - nothing to configure".into()))?;
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    Ok((path, text))
}

/// Dev shell additions the app can toggle, and whether each is live yet.
///
/// `verified_by` names the panel stat that confirms it, so "enabled" and
/// "actually there" stay separate facts - the same distinction the settings
/// page makes between declared and in effect.
async fn list_devshell(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let (path, text) = devshell_file()?;
    let enabled = crate::devshell::read_enabled(&text);

    // Look the confirming stat up in the panel that owns it, rather than
    // re-measuring here - one source for the fact.
    let panels = state.registry.summaries();
    let live = |reference: &str| -> Value {
        let Some((panel_id, stat)) = reference.split_once('.') else {
            return Value::Null;
        };
        panels
            .iter()
            .find(|p| p.meta.id == panel_id)
            .and_then(|p| p.latest.as_ref())
            .map(|s| s.value[stat].clone())
            .unwrap_or(Value::Null)
    };

    let extras: Vec<Value> = crate::devshell::known()
        .into_iter()
        .map(|e| {
            let mut obj = serde_json::to_value(&e).unwrap_or_else(|_| json!({}));
            if let Some(map) = obj.as_object_mut() {
                map.insert(
                    "enabled".into(),
                    Value::Bool(enabled.iter().any(|k| k == e.key)),
                );
                map.insert("live".into(), live(e.verified_by));
            }
            obj
        })
        .collect();

    Ok(Json(json!({
        "path": path.display().to_string(),
        "exists": path.exists(),
        "extras": extras,
    })))
}

/// Turn one addition on or off.
///
/// Writes the generated file and nothing else. Taking effect needs a new
/// shell - `nix develop` - which the response says rather than leaving you to
/// wonder why the panel has not moved.
async fn toggle_devshell(
    Json(toggle): Json<DevshellToggle>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let (path, text) = devshell_file()?;
    let plan = crate::devshell::plan(
        &text,
        &path.display().to_string(),
        &toggle.key,
        toggle.enabled,
    )
    .map_err(|e| ApiError::NotRunnable(e.to_string()))?;

    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| ApiError::Internal(format!("creating {}: {e}", dir.display())))?;
    }
    std::fs::write(&path, &plan.rendered)
        .map_err(|e| ApiError::Internal(format!("writing {}: {e}", path.display())))?;

    tracing::info!(key = %plan.key, enabled = plan.enabled, "toggled dev shell extra");

    Ok(Json(json!({
        "written": true,
        "path": plan.path,
        "key": plan.key,
        "enabled": plan.enabled,
        "diff": plan.diff,
        "live": false,
        "next_step": "Re-enter the development shell with `nix develop` for \
                      this to take effect. Nothing has changed in the shell \
                      you already have open.",
    })))
}

#[derive(Debug, Deserialize)]
pub struct SystemToggle {
    key: String,
    enabled: bool,
}

/// System additions, and how far along each one is.
///
/// Three states rather than two, because getting a file into /etc is a
/// privileged step that happens separately: *staged* here, *installed* in
/// /etc/nixos, *live* after a rebuild. Collapsing them would mean claiming a
/// change that has not happened.
async fn list_system(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let staged_path = crate::system::staged_path()
        .ok_or_else(|| ApiError::Internal("no HOME, cannot stage".into()))?;
    let staged_text = std::fs::read_to_string(&staged_path).unwrap_or_default();

    let installed_path = crate::system::installed_path();
    // Readable without privilege; only writing needs root.
    let installed_text = std::fs::read_to_string(&installed_path).unwrap_or_default();

    let staged = crate::system::read_enabled(&staged_text);
    let installed = crate::system::read_enabled(&installed_text);

    let panels = state.registry.summaries();
    let live = |reference: &str| -> Value {
        let Some((panel_id, stat)) = reference.split_once('.') else {
            return Value::Null;
        };
        panels
            .iter()
            .find(|p| p.meta.id == panel_id)
            .and_then(|p| p.latest.as_ref())
            .map(|s| s.value[stat].clone())
            .unwrap_or(Value::Null)
    };

    let entries: Vec<Value> = crate::system::known()
        .into_iter()
        .map(|e| {
            let mut obj = serde_json::to_value(&e).unwrap_or_else(|_| json!({}));
            if let Some(map) = obj.as_object_mut() {
                map.insert(
                    "staged".into(),
                    Value::Bool(staged.iter().any(|k| k == e.key)),
                );
                map.insert(
                    "installed".into(),
                    Value::Bool(installed.iter().any(|k| k == e.key)),
                );
                map.insert("live".into(), live(e.verified_by));
            }
            obj
        })
        .collect();

    Ok(Json(json!({
        "staged_path": staged_path.display().to_string(),
        "installed_path": installed_path.display().to_string(),
        "installed_exists": installed_path.exists(),
        // Whether configuration.nix actually imports the generated file.
        // Without that line the file is inert, and saying so is better than
        // letting someone wonder why a rebuild changed nothing.
        "imported": std::fs::read_to_string("/etc/nixos/configuration.nix")
            .map(|c| c.contains("nixdash-system.nix"))
            .unwrap_or(false),
        "entries": entries,
    })))
}

/// Stage one system addition.
///
/// Writes only into the app's own directory in your home. Nothing here
/// touches /etc - that is the install action, and its polkit prompt.
async fn toggle_system(
    Json(toggle): Json<SystemToggle>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let staged_path = crate::system::staged_path()
        .ok_or_else(|| ApiError::Internal("no HOME, cannot stage".into()))?;
    let current = std::fs::read_to_string(&staged_path).unwrap_or_default();

    let plan = crate::system::plan(
        &current,
        &staged_path.display().to_string(),
        &toggle.key,
        toggle.enabled,
    )
    .map_err(|e| ApiError::NotRunnable(e.to_string()))?;

    if let Some(dir) = staged_path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| ApiError::Internal(format!("creating {}: {e}", dir.display())))?;
    }
    std::fs::write(&staged_path, &plan.rendered)
        .map_err(|e| ApiError::Internal(format!("writing {}: {e}", staged_path.display())))?;

    tracing::info!(key = %plan.key, enabled = plan.enabled, "staged system addition");

    Ok(Json(json!({
        "staged": true,
        "installed": false,
        "path": plan.staged_path,
        "key": plan.key,
        "enabled": plan.enabled,
        "diff": plan.diff,
        "next_step": "Nothing under /etc has changed. An install action is \
                      now offered; it asks polkit for permission to copy this \
                      into /etc/nixos, and a rebuild applies it after that.",
    })))
}

#[derive(Debug, Deserialize)]
pub struct HistoryQuery {
    /// Number of samples to return, newest last.
    limit: Option<usize>,
}

async fn panel_history(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<HistoryQuery>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let panel = state
        .registry
        .get(&id)
        .ok_or_else(|| ApiError::NotFound(format!("no panel {id}")))?;

    let limit = q.limit.unwrap_or(120).min(1000);
    Ok(Json(json!({
        "meta": panel.meta,
        "error": panel.error(),
        "samples": panel.history(limit),
    })))
}

pub enum ApiError {
    NotFound(String),
    /// The action exists but has nothing executable - a Nix snippet.
    NotRunnable(String),
    Internal(String),
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            ApiError::NotFound(m) => (StatusCode::NOT_FOUND, m),
            // 422, not 404: the action is real and was found, it just is not
            // the kind of thing that runs.
            ApiError::NotRunnable(m) => (StatusCode::UNPROCESSABLE_ENTITY, m),
            ApiError::Internal(m) => (StatusCode::INTERNAL_SERVER_ERROR, m),
        };
        (status, Json(json!({ "error": message }))).into_response()
    }
}
