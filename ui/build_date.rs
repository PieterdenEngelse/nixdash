// When a build was produced, for the About link in the header.
//
// `include!`d by all three build scripts rather than duplicated:
// `ui-wasm/rust/build_date.rs` and `engine/build_date.rs` are symlinks to
// this file, the same trick `src/cxxqt_object.rs` already uses. The three
// `build.rs` files differ elsewhere, so only the shared part is linked.
//
// The engine needs it for the same reason the UIs do, plus one more: its
// freshness panel compares the running binary against source on disk, and a
// store path's mtime cannot answer when it was built.
//
// std only, which is why the calendar arithmetic is here in full. A
// `chrono` + `chrono-tz` dependency to format one timestamp would pull a
// timezone database into a build script that needs exactly one zone.
//
// Plain `//` and not `//!`, deliberately: `include!` splices this text into
// the middle of a `build.rs`, and an inner doc comment is only legal at the
// top of a module. Promoting these back to `//!` is error E0753.

/// `YYYY-MM-DD`, from a day count since the Unix epoch.
///
/// civil_from_days, from Howard Hinnant's date algorithms. The epoch is
/// shifted to 0000-03-01 so that February - and therefore the leap day -
/// falls at the END of the year; that is what makes the month and day
/// arithmetic plain division with no leap-year special case.
#[allow(dead_code)]
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // day of era, [0, 146096]
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of shifted year
    let mp = (5 * doy + 2) / 153; // shifted month, [0, 11] with March = 0
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// The inverse, needed to locate the daylight-saving boundaries.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = y - i64::from(m <= 2);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// 0 = Sunday. 1970-01-01 was a Thursday, hence the +4.
fn weekday(days: i64) -> i64 {
    if days >= -4 {
        (days + 4) % 7
    } else {
        (days + 5) % 7 + 6
    }
}

/// Seconds east of UTC for Europe/Amsterdam at `secs`.
///
/// The EU rule, hardcoded: summer time runs from 01:00 UTC on the last
/// Sunday in March to 01:00 UTC on the last Sunday in October. Hardcoded
/// rather than read from `/etc/localtime`, because this also has to be right
/// inside the Nix build sandbox, where TZ is UTC and there is no local zone
/// to read. Amsterdam is the only zone this project displays.
///
/// If the EU ever does abolish the clock change, this is the one place to
/// fix - and the symptom will be an About stamp an hour out in summer.
#[allow(dead_code)]
fn amsterdam_offset(secs: i64) -> i64 {
    let (y, _, _) = civil_from_days(secs.div_euclid(86_400));
    // Both March and October have 31 days, so the last Sunday is simply the
    // 31st walked back to the previous Sunday.
    let last_sunday = |m: i64| 31 - weekday(days_from_civil(y, m, 31));
    let starts = days_from_civil(y, 3, last_sunday(3)) * 86_400 + 3_600;
    let ends = days_from_civil(y, 10, last_sunday(10)) * 86_400 + 3_600;
    if secs >= starts && secs < ends {
        7_200 // CEST
    } else {
        3_600 // CET
    }
}

/// `YYYY-MM-DD HH:MM` in Amsterdam time, for the moment the build ran.
///
/// There is no runtime answer to this question. A Nix store path's mtime is
/// pinned to the epoch by design, and the process start time says when you
/// opened the window, not when the binary was made - which is the thing you
/// actually want to know when the UI looks like it ignored your edit.
///
/// Takes the instant rather than reading the clock, so that the string and
/// the epoch emitted beside it describe the same moment.
#[allow(dead_code)]
fn build_stamp(utc: i64) -> String {
    let local = utc + amsterdam_offset(utc);
    let (y, m, d) = civil_from_days(local.div_euclid(86_400));
    let sod = local.rem_euclid(86_400);
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02}", sod / 3_600, sod % 3_600 / 60)
}

/// Hands the build moment to the crate twice: `env!("NIXDASH_BUILT")` to
/// show someone, and `env!("NIXDASH_BUILT_AT")` as Unix seconds to compute
/// with.
///
/// Both, because they are read by different kinds of code. The string is for
/// an About box and is formatted for one timezone; the epoch is for
/// comparing against a source file's mtime, where parsing the string back
/// would mean re-deriving the offset at runtime to undo it.
///
/// Cargo only re-runs a build script when something it declared changes, and
/// cxx-qt declares the QML files and `src/`. So this is "when the build
/// script last ran", not "when you last typed cargo build" - which is the
/// honest answer anyway: an untouched tree produces the same binary.
///
/// It is also the START of that build and not its end, because a build
/// script runs before anything is compiled. The desktop build makes that
/// gap look like nothing; the wasm one does not, where an emcc link of
/// several minutes leaves the stamp reading earlier than the bundle's own
/// mtime by exactly that long. A fresh browser build therefore looks stale
/// next to the file it just wrote, and the two numbers disagreeing is
/// correct rather than a fault. The About panel says "build started" for
/// this reason - if that label ever drifts back to "built", this is the
/// paragraph explaining why it should not.
#[allow(dead_code)]
fn emit_build_date() {
    let utc = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    println!("cargo:rustc-env=NIXDASH_BUILT={}", build_stamp(utc));
    println!("cargo:rustc-env=NIXDASH_BUILT_AT={utc}");
}
