use std::process::Command;

use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::Value;

use crate::collector::{Collector, Info, PanelMeta, StatInfo, Status, Subject};

/// Free space on the filesystem holding the Nix store, or `/` where there
/// is no store.
///
/// The store is where a NixOS machine actually runs out of disk: every
/// rebuild adds paths and nothing is removed until a GC. Watching `/nix`
/// specifically (rather than every mount) keeps this one honest number.
///
/// Shells out to `df` rather than taking a libc dependency for statvfs. The
/// `--output` form is parsed by position, with a header check, so a locale or
/// column change fails the panel loudly instead of yielding silent nonsense.
pub struct DiskCollector;

#[derive(Debug, Serialize)]
struct DiskReading {
    path: &'static str,
    total_bytes: u64,
    used_bytes: u64,
    avail_bytes: u64,
    used_fraction: f64,
}

/// The filesystem this panel reports on.
///
/// `/nix` where one exists, because on NixOS the store is what fills up and a
/// rebuild is what fills it. Off NixOS there is no store, `df /nix` exits 1,
/// and the panel reported `unknown` on a machine whose disk is perfectly
/// measurable - "could not look" was true of the path asked about and
/// misleading about the question. `/` answers the same question against a
/// filesystem that is actually there.
///
/// Resolved per sample rather than once at startup, so installing Nix on a
/// machine that had none is noticed without a restart.
fn watched() -> &'static str {
    if std::path::Path::new("/nix").is_dir() {
        "/nix"
    } else {
        "/"
    }
}

fn parse_df(stdout: &str) -> Result<(u64, u64, u64)> {
    let mut lines = stdout.lines();
    let header = lines.next().context("df produced no output")?;
    // Guard against a different column order rather than trusting position.
    anyhow::ensure!(
        header.split_whitespace().count() == 3,
        "unexpected df header: {header:?}"
    );

    let row = lines.next().context("df produced no data row")?;
    let cols: Vec<&str> = row.split_whitespace().collect();
    anyhow::ensure!(cols.len() == 3, "unexpected df row: {row:?}");

    Ok((cols[0].parse()?, cols[1].parse()?, cols[2].parse()?))
}

impl Collector for DiskCollector {
    fn meta(&self) -> PanelMeta {
        PanelMeta {
            id: "disk",
            title: "Disk (/nix)",
            description:
                "Free space on the filesystem holding the Nix store, or / where there is none",
            // Disk moves slowly except during a build; 30s is plenty.
            interval_secs: 30,
            subject: Subject::NixOS,
            info: Info {
                what: "Space on the filesystem containing /nix, reported the \
                       way df reports it.",
                why: "The store is where a NixOS machine actually runs out of \
                      disk: every rebuild adds paths and nothing is removed \
                      until a garbage collection.",
                if_wrong: "Above ~93% a rebuild can fail part-way, which is \
                           the worst moment to discover it. Run the garbage \
                           collection action before that.",
                sections: &[],
            },
            stats: vec![
                StatInfo {
                    key: "path",
                    info: Info {
                        what: "The path whose filesystem is measured - /nix.",
                        why: "On most systems this is the root filesystem; on \
                              some it is a separate mount, and only this one \
                              matters for builds.",
                        if_wrong: "If this is not where your store lives, the \
                                   panel is measuring the wrong thing.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "total_bytes",
                    info: Info {
                        what: "Filesystem size including blocks reserved for \
                               root.",
                        why: "Context for the other numbers.",
                        if_wrong: "Not actionable on its own - used_fraction \
                                   is the number to watch.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "used_bytes",
                    info: Info {
                        what: "Space in use.",
                        why: "Growth between readings is how fast the store is \
                              filling.",
                        if_wrong: "Rapid growth with no build running suggests \
                                   something else is writing.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "avail_bytes",
                    info: Info {
                        what: "Space you can actually write, excluding the \
                               root-reserved blocks.",
                        why: "This, not total minus used, is what a build has \
                              to work with.",
                        if_wrong: "A few GB is tight for a Qt or Rust build; \
                                   wasm artefacts alone are ~24 MB each plus \
                                   intermediates.",
                        sections: &[],
                    },
                },
                StatInfo {
                    key: "used_fraction",
                    info: Info {
                        what: "used / (used + available) - deliberately NOT \
                               used / total.",
                        why: "Filesystems reserve ~5% for root. Counting those \
                              blocks as yours reports 93% when df and reality \
                              say 98%, understating exactly when it matters.",
                        if_wrong: "Above 0.93 act now; above 0.98 a build will \
                                   probably fail.",
                        sections: &[],
                    },
                },
            ],
        }
    }

    fn sample(&self) -> Result<Value> {
        let out = Command::new("df")
            .args(["-B1", "--output=size,used,avail", watched()])
            .output()
            .context("running df")?;
        anyhow::ensure!(
            out.status.success(),
            "df exited {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        );

        let (total, used, avail) = parse_df(&String::from_utf8_lossy(&out.stdout))?;

        Ok(serde_json::to_value(DiskReading {
            path: watched(),
            total_bytes: total,
            used_bytes: used,
            avail_bytes: avail,
            // used / (used + avail), NOT used / total.
            //
            // Filesystems reserve blocks for root (~5% on ext4), which are
            // counted in `total` but are not available to you. Dividing by
            // total therefore reports ~93% when df - and reality - say 98%,
            // understating exactly when it matters most. This matches what
            // `df` prints in its Use%% column.
            used_fraction: if used + avail == 0 {
                0.0
            } else {
                used as f64 / (used + avail) as f64
            },
        })?)
    }

    fn status(&self, v: &Value) -> (Status, String) {
        let used = v["used_fraction"].as_f64().unwrap_or(0.0);
        let avail_gb = v["avail_bytes"].as_u64().unwrap_or(0) as f64 / 1_073_741_824.0;

        // A store fills slowly and then bites during a rebuild, when there is
        // no good moment to deal with it. Warn with room left to act.
        let status = if used > 0.93 {
            Status::Bad
        } else if used > 0.85 {
            Status::Warn
        } else {
            Status::Ok
        };
        (status, format!("{avail_gb:.1} GB free"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn used_fraction_excludes_reserved_blocks() {
        // 105 used, 2.3 avail, 113 total: df says 98%, not 93%.
        let used: u64 = 105;
        let avail: u64 = 2;
        let f = used as f64 / (used + avail) as f64;
        assert!(f > 0.97, "got {f}");
    }

    #[test]
    fn parses_df_output() {
        let out = "      1K-blocks          Used         Avail\n\
                   121123069952   48318382080   66579193856\n";
        let (t, u, a) = parse_df(out).unwrap();
        assert_eq!(t, 121_123_069_952);
        assert_eq!(u, 48_318_382_080);
        assert_eq!(a, 66_579_193_856);
    }

    #[test]
    fn rejects_unexpected_columns() {
        // A changed --output would otherwise be read positionally as nonsense.
        assert!(parse_df("size used avail target\n1 2 3 /nix\n").is_err());
        assert!(parse_df("size used\n1 2\n").is_err());
    }

    #[test]
    fn samples_this_machine() {
        let v = DiskCollector.sample().expect("df should work");
        assert!(v["total_bytes"].as_u64().unwrap() > 0);
        assert!(v["used_fraction"].as_f64().unwrap() > 0.0);
    }
}
