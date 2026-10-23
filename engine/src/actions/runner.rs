use std::{process::Command, time::Duration};

use serde::Serialize;

use super::RunCommand;

/// How long a single action may run before it is given up on.
///
/// `nixos-rebuild switch` can legitimately take many minutes, so this is
/// generous. It exists to stop a wedged command holding a worker forever, not
/// to bound honest work.
const TIMEOUT: Duration = Duration::from_secs(1800);

#[derive(Debug, Clone, Serialize)]
pub struct RunOutcome {
    /// The exact argv that was executed, so what happened is inspectable
    /// afterwards rather than inferred from the display text.
    pub argv: Vec<String>,
    pub elevated: bool,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    /// Set when the engine could not even start the command.
    pub error: Option<String>,
}

impl RunOutcome {
    pub fn succeeded(&self) -> bool {
        self.error.is_none() && self.exit_code == Some(0)
    }
}

/// What starting a detached process told us - which is less than it looks.
///
/// There is deliberately no `succeeded()` here, unlike `RunOutcome`. A
/// successful fork is not a running server, and a method called `succeeded`
/// would be read as one. Whether it is up is a question for a probe.
#[derive(Debug, Clone, Serialize)]
pub struct SpawnOutcome {
    pub argv: Vec<String>,
    /// Set when the child was already gone a moment after starting, with its
    /// exit status. This is the ONLY way an exec failure is visible here:
    /// `setsid` forks successfully and only then fails to exec, so the
    /// spawner gets a pid for a process that never ran the target. Checking
    /// /proc for that pid does not help - a zombie has a /proc entry, which
    /// is how a "started" window came to close two real ones.
    pub exited: Option<i32>,
    /// Where its output went, so a process with no terminal can still say why
    /// it died.
    pub log: String,
    pub pid: Option<u32>,
    /// Set when the fork itself failed.
    pub error: Option<String>,
}

/// Where NixOS keeps setuid binaries. MUST be searched before the system
/// profile.
///
/// This is a NixOS-specific trap that costs an afternoon if you miss it.
/// `/run/current-system/sw/bin/pkexec` exists and is mode `r-xr-xr-x` - not
/// setuid. The setuid copy is a separate wrapper in `/run/wrappers/bin`. Run
/// the one in the system profile and pkexec refuses immediately, complaining
/// that it is not setuid root, which reads like a broken polkit install rather
/// than the wrong path to the right program.
const WRAPPER_BIN: &str = "/run/wrappers/bin";

/// Where NixOS puts the system profile's binaries.
const SYSTEM_BIN: &str = "/run/current-system/sw/bin";

/// Resolve a program name to an absolute path when we can.
///
/// This matters specifically under pkexec. pkexec deliberately discards the
/// caller's environment and hands the program a sanitised
/// `PATH=/usr/sbin:/usr/bin:/sbin:/bin` - which on NixOS is very nearly empty.
/// A bare `systemctl` would resolve from *our* PATH at spawn time, but
/// anything the program then shells out to would not. Naming the absolute path
/// is both more precise about what is being run and the only form that
/// survives the environment being stripped.
fn resolve_program(program: &str) -> String {
    if program.starts_with('/') {
        return program.to_string();
    }
    for dir in [WRAPPER_BIN, SYSTEM_BIN] {
        let candidate = format!("{dir}/{program}");
        if std::path::Path::new(&candidate).exists() {
            return candidate;
        }
    }
    // Leave it bare and let exec report ENOENT, which `run` turns into a
    // readable "could not start" rather than a silent failure.
    program.to_string()
}

/// Build the argv actually handed to the OS.
///
/// Elevation goes through `pkexec`, never `sudo`: sudo wants a terminal and a
/// password on stdin, which a background service does not have, and would
/// either hang or silently fail. pkexec raises a desktop prompt that you
/// answer - which is the point. `--disable-internal-agent` makes it fail
/// cleanly when no polkit agent is running, instead of blocking forever on a
/// prompt nobody can see.
fn argv_for(cmd: &RunCommand) -> Vec<String> {
    let mut argv = Vec::new();
    if cmd.elevate {
        argv.push(resolve_program("pkexec"));
        argv.push("--disable-internal-agent".to_string());
    }
    argv.push(resolve_program(&cmd.program));
    argv.extend(cmd.args.iter().cloned());
    argv
}

/// Execute one action.
///
/// Note what this does NOT do: no shell. The program and arguments are passed
/// to exec directly, so nothing in them is word-split, glob-expanded or
/// interpreted. An action's arguments come from system state (a unit name, for
/// instance), and routing those through `sh -c` would turn a strangely named
/// unit into command injection.
/// Run it, and write what it prints to `log` as it arrives.
///
/// Both streams go to one file, interleaved as they were produced, because
/// that is the order a terminal would have shown them in and the order the
/// failure has to be read in.
pub fn run_logged(cmd: &RunCommand, log: Option<&std::path::Path>) -> RunOutcome {
    run_inner(cmd, log)
}

pub fn run(cmd: &RunCommand) -> RunOutcome {
    run_inner(cmd, None)
}

fn run_inner(cmd: &RunCommand, log: Option<&std::path::Path>) -> RunOutcome {
    let argv = argv_for(cmd);
    let mut outcome = RunOutcome {
        argv: argv.clone(),
        elevated: cmd.elevate,
        exit_code: None,
        stdout: String::new(),
        stderr: String::new(),
        error: None,
    };

    tracing::info!(argv = ?argv, elevated = cmd.elevate, "running action");

    let mut command = Command::new(&argv[0]);
    if let Some(dir) = &cmd.cwd {
        command.current_dir(dir);
    }
    let mut child = match command
        .args(&argv[1..])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            outcome.error = Some(format!("could not start {}: {e}", argv[0]));
            return outcome;
        }
    };

    // Drain both pipes on their own threads. This is not tidiness: a pipe
    // holds about 64K, and `nixos-rebuild switch` emits far more than that.
    // Polling try_wait() without reading would block the child on a full pipe
    // while we waited for it to exit - a deadlock that only ends at the
    // timeout, and looks exactly like a slow rebuild.
    // Truncated at the start of each run: a log showing the previous attempt
    // under a command that is running now is worse than no log.
    let sink = log
        .and_then(|p| std::fs::File::create(p).ok())
        .map(|f| std::sync::Arc::new(std::sync::Mutex::new(f)));
    let out_pipe = child.stdout.take().map(|r| drain(r, sink.clone()));
    let err_pipe = child.stderr.take().map(|r| drain(r, sink.clone()));

    // wait_timeout would need another dependency; polling is adequate for a
    // handful of long-running commands and keeps the dependency list honest.
    let deadline = std::time::Instant::now() + TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {
                if std::time::Instant::now() > deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    outcome.error = Some(format!(
                        "timed out after {} minutes",
                        TIMEOUT.as_secs() / 60
                    ));
                    break None;
                }
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(e) => {
                outcome.error = Some(format!("waiting for {}: {e}", argv[0]));
                break None;
            }
        }
    };

    // The readers end when the child closes its pipes, which has happened by
    // the time it is reaped or killed, so these joins do not add waiting.
    outcome.stdout = out_pipe.map(collect).unwrap_or_default();
    outcome.stderr = err_pipe.map(collect).unwrap_or_default();
    outcome.exit_code = status.and_then(|s| s.code());

    // pkexec's own failure modes are indistinguishable from the command's
    // without this: 126 is "not authorised or dismissed", 127 is "could not
    // run at all". Both would otherwise be reported as the action failing.
    if cmd.elevate && outcome.error.is_none() {
        match outcome.exit_code {
            Some(126) => {
                outcome.error = Some(
                    "not authorised - the polkit prompt was dismissed, or no \
                     agent is running to show it"
                        .into(),
                )
            }
            Some(127) => outcome.error = Some("pkexec could not run the command".into()),
            _ => {}
        }
    }

    outcome
}

/// Start something that is meant to keep running, and do not wait for it.
///
/// For a server, exiting IS the failure, so every assumption `run` is built on
/// is inverted: there is no exit code worth waiting for, and waiting at all
/// would hold the request until the timeout killed the very process that was
/// asked for.
///
/// Three things this must get right, each of which has its own failure if
/// missed:
///
/// - **Output goes to a file, never to a pipe.** Nobody is draining it, and a
///   pipe holds about 64K - a server logging into a full pipe blocks forever,
///   which looks like a hang in the thing you just started. The path is
///   returned so the page can name it, because a process with no terminal has
///   nowhere else to put its reason for dying.
/// - **Its own process group**, via `setsid`. Otherwise it is in the engine's
///   group and dies with it, so restarting the service would silently take
///   down a dev engine you started hours ago.
/// - **Success here is not success.** This returns once the fork succeeded,
///   which says nothing about whether the port was free or the binary ran.
///   Only a probe can answer that, and the caller must do one.
pub fn spawn_detached(
    cmd: &RunCommand,
    log: &std::path::Path,
    env: &[(&str, String)],
) -> SpawnOutcome {
    let argv = argv_for(cmd);
    let mut outcome = SpawnOutcome {
        argv: argv.clone(),
        exited: None,
        log: log.display().to_string(),
        pid: None,
        error: None,
    };

    let file = match std::fs::File::create(log) {
        Ok(f) => f,
        Err(e) => {
            outcome.error = Some(format!("could not open {}: {e}", log.display()));
            return outcome;
        }
    };
    let errfile = match file.try_clone() {
        Ok(f) => f,
        Err(e) => {
            outcome.error = Some(format!("could not open {} twice: {e}", log.display()));
            return outcome;
        }
    };

    tracing::info!(argv = ?argv, log = %log.display(), "starting detached");

    // setsid rather than a libc call: this crate has no unsafe and no libc
    // dependency, and `setsid` is in the system profile on any NixOS machine.
    // It execs the target, so the pid reported is the one that matters.
    let mut command = Command::new(resolve_program("setsid"));
    command.arg("--");
    command.args(&argv);
    if let Some(dir) = &cmd.cwd {
        command.current_dir(dir);
    }
    for (k, v) in env {
        command.env(k, v);
    }

    match command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::from(file))
        .stderr(std::process::Stdio::from(errfile))
        .spawn()
    {
        Ok(mut child) => {
            outcome.pid = Some(child.id());
            // Watch it briefly. An exec failure, a missing display or a
            // refused port all end the process within milliseconds, and this
            // is the only moment the truth is cheap to get. try_wait also
            // REAPS it, so a failed start does not leave a zombie behind
            // whose /proc entry would read as a running program.
            let deadline = std::time::Instant::now() + Duration::from_millis(600);
            while std::time::Instant::now() < deadline {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        outcome.exited = Some(status.code().unwrap_or(-1));
                        break;
                    }
                    Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                    Err(e) => {
                        outcome.error = Some(format!("waiting on {}: {e}", argv[0]));
                        break;
                    }
                }
            }
        }
        Err(e) => outcome.error = Some(format!("could not start {}: {e}", argv[0])),
    }

    outcome
}

impl SpawnOutcome {
    /// Started, and still running a moment later. Deliberately not called
    /// `succeeded`: a window that is up is not necessarily a window you can
    /// see, and only the person at the screen can say that.
    pub fn still_running(&self) -> bool {
        self.error.is_none() && self.pid.is_some() && self.exited.is_none()
    }
}

/// Stop something `spawn_detached` started.
///
/// `setsid` execs the target, so the recorded pid is the process itself and a
/// plain TERM reaches it. Reported honestly: "no such process" means it had
/// already gone, which is not a failure to stop it.
pub fn stop(pid: u32) -> Result<(), String> {
    let out = Command::new(resolve_program("kill"))
        .arg("-TERM")
        .arg(pid.to_string())
        .output()
        .map_err(|e| format!("could not run kill: {e}"))?;
    if out.status.success() {
        return Ok(());
    }
    let why = String::from_utf8_lossy(&out.stderr).trim().to_string();
    Err(if why.is_empty() {
        format!("kill {pid} failed")
    } else {
        why
    })
}

/// Read a pipe to its end, optionally copying what arrives to a file.
///
/// `read_to_end` was enough while the only reader was the caller waiting for
/// the whole thing. It is not enough for something that takes fifteen
/// minutes: nobody can see a single byte until the command exits, so a
/// `home-manager switch` was fifteen minutes of an unchanging screen with no
/// way to tell work from a hang.
///
/// So this reads in CHUNKS and appends each one, which is what makes the log
/// readable while the command is still running. Still bytes, not lines: a
/// build that writes a progress bar with no newline would otherwise show
/// nothing at all, which is the case that most needs showing.
///
/// Flushed per chunk, since the file is being read by another thread
/// answering a request. Unflushed output is indistinguishable from a command
/// that has gone quiet.
fn drain<R: std::io::Read + Send + 'static>(
    mut r: R,
    log: Option<std::sync::Arc<std::sync::Mutex<std::fs::File>>>,
) -> std::thread::JoinHandle<String> {
    std::thread::spawn(move || {
        use std::io::Write;
        let mut all = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            match r.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    all.extend_from_slice(&chunk[..n]);
                    if let Some(f) = &log {
                        if let Ok(mut f) = f.lock() {
                            let _ = f.write_all(&chunk[..n]);
                            let _ = f.flush();
                        }
                    }
                }
            }
        }
        String::from_utf8_lossy(&all).trim_end().to_string()
    })
}

fn collect(h: std::thread::JoinHandle<String>) -> String {
    h.join().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cmd(program: &str, args: &[&str], elevate: bool) -> RunCommand {
        RunCommand {
            program: program.into(),
            args: args.iter().map(|s| s.to_string()).collect(),
            elevate,
            cwd: None,
        }
    }

    #[test]
    fn elevated_commands_go_through_pkexec_not_sudo() {
        let argv = argv_for(&cmd("systemctl", &["restart", "x"], true));
        assert!(argv[0].ends_with("pkexec"), "{argv:?}");
        assert!(argv.contains(&"--disable-internal-agent".to_string()));
        // sudo would need a tty and a password on stdin; a background service
        // has neither, so it must never appear.
        assert!(!argv.iter().any(|a| a.ends_with("sudo")), "{argv:?}");
    }

    #[test]
    fn unelevated_commands_exec_directly_with_arguments_intact() {
        let argv = argv_for(&cmd("systemctl", &["--user", "restart", "x"], false));
        assert!(argv[0].ends_with("systemctl"), "{argv:?}");
        assert_eq!(&argv[1..], ["--user", "restart", "x"]);
    }

    #[test]
    fn absolute_paths_are_left_alone() {
        assert_eq!(resolve_program("/bin/sh"), "/bin/sh");
    }

    /// Guards the trap documented on WRAPPER_BIN: the system-profile pkexec is
    /// not setuid, so resolving to it means pkexec can never escalate.
    #[test]
    fn pkexec_resolves_to_the_setuid_wrapper() {
        let wrapper = format!("{WRAPPER_BIN}/pkexec");
        if !std::path::Path::new(&wrapper).exists() {
            eprintln!("no {wrapper} on this machine - skipping");
            return;
        }
        assert_eq!(resolve_program("pkexec"), wrapper);
    }

    #[test]
    fn unresolvable_programs_stay_bare_for_exec_to_reject() {
        assert_eq!(
            resolve_program("nixdash-definitely-not-installed"),
            "nixdash-definitely-not-installed"
        );
    }

    #[test]
    fn arguments_are_not_shell_interpreted() {
        // A unit name is system-supplied. If argv went through a shell this
        // would run `touch`; passed to exec it is just a strange argument.
        let out = run(&cmd(
            "echo",
            &["; touch /tmp/nixdash-injection-canary"],
            false,
        ));
        assert!(out.succeeded(), "{out:?}");
        assert!(out.stdout.contains("touch"), "argument should be literal");
        assert!(
            !std::path::Path::new("/tmp/nixdash-injection-canary").exists(),
            "argument was executed by a shell"
        );
    }

    #[test]
    fn reports_a_missing_program_rather_than_panicking() {
        let out = run(&cmd("nixdash-no-such-program", &[], false));
        assert!(!out.succeeded());
        assert!(out.error.unwrap().contains("could not start"));
    }

    #[test]
    fn captures_exit_code_and_streams() {
        let out = run(&cmd("sh", &["-c", "echo out; echo err >&2; exit 3"], false));
        assert_eq!(out.exit_code, Some(3));
        assert_eq!(out.stdout, "out");
        assert_eq!(out.stderr, "err");
        assert!(!out.succeeded());
    }
}
