use std::{env, fs, path::Path, process::Command};

/// The window reports what build it is, and it has to agree with the release it
/// starts: a crash report naming two different builds is worse than one naming
/// none.
///
/// `mix build.info` writes `priv/build_info.json` moments before this crate is
/// compiled (`scripts/package.sh` runs them in that order), so that file is the
/// source. An environment variable still wins, and a checkout that never ran the
/// task falls back to what git and Cargo can say on their own.
fn main() {
    println!("cargo:rerun-if-changed=../priv/build_info.json");

    for key in ["BUILD_VERSION", "BUILD_REVISION", "BUILD_BUILT_AT"] {
        println!("cargo:rerun-if-env-changed={key}");
    }

    let recorded = fs::read_to_string("../priv/build_info.json").unwrap_or_default();

    emit(
        "BUILD_VERSION",
        &[
            env::var("BUILD_VERSION").ok(),
            field(&recorded, "version"),
            git(&["describe", "--tags", "--always", "--dirty"]),
            Some(env!("CARGO_PKG_VERSION").to_string()),
        ],
    );

    emit(
        "BUILD_REVISION",
        &[
            env::var("BUILD_REVISION").ok(),
            field(&recorded, "revision"),
            git(&["rev-parse", "--short", "HEAD"]),
        ],
    );

    emit(
        "BUILD_BUILT_AT",
        &[
            env::var("BUILD_BUILT_AT").ok(),
            field(&recorded, "built_at"),
            Some("an unrecorded build".to_string()),
        ],
    );

    tauri_build::build()
}

/// The first answer that exists, as a compile-time environment variable.
fn emit(name: &str, candidates: &[Option<String>]) {
    let value = candidates
        .iter()
        .flatten()
        .map(|candidate| candidate.trim())
        .find(|candidate| !candidate.is_empty())
        .unwrap_or("unknown");

    println!("cargo:rustc-env={name}={value}");
}

/// One string value out of the small, fixed object our own task writes. A JSON
/// parser is not worth a build dependency for three keys of known shape, and a
/// missing or malformed file is not an error: the fallbacks handle it.
fn field(json: &str, key: &str) -> Option<String> {
    let after_key = json.find(&format!("\"{key}\":"))? + key.len() + 3;
    let rest = json[after_key..].strip_prefix('"')?;

    Some(rest[..rest.find('"')?].to_string())
}

fn git(args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(Path::new(".."))
        .output()
        .ok()?;

    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_string())
}
