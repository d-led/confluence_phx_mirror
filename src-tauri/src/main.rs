//! The window, and the sidecar behind it.
//!
//! Tauri is a window here, and a process supervisor, and nothing else. It starts
//! the Elixir release, reads the address that release prints, and points a
//! webview at it. Everything the tool does lives in the sidecar — the same
//! binary a headless machine would run — so the window adds no behaviour and
//! cannot drift from the server.

use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

/// The sidecar, kept so it can be stopped when the window goes away. A window
/// closed over a server still running is a port nobody can find again, holding
/// a database open.
struct Sidecar(Mutex<Option<Child>>);

/// Why the release could not be started, and where its own log went.
///
/// A failure is not exceptional — the file can be missing, the release can stop
/// before it speaks — so it is a value, not a panic. A panic in `setup` unwinds
/// through AppKit's Apple Event dispatch, which macOS reports as `Confluence
/// Export quit unexpectedly` with the one useful sentence on a stderr that a
/// double-clicked app does not have. That is how a *reason* reached a person as
/// a crash dialog, twice on 4 November and once on 2 November.
struct Failure {
    message: String,
    log: Option<PathBuf>,
}

fn main() {
    tauri::Builder::default()
        .manage(Sidecar(Mutex::new(None)))
        .setup(|app| {
            match start_sidecar(app) {
                Ok((child, url)) => {
                    app.state::<Sidecar>().0.lock().unwrap().replace(child);

                    WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse()?))
                        .title("Confluence Export")
                        .inner_size(1024.0, 760.0)
                        .min_inner_size(720.0, 560.0)
                        .build()?;
                }
                Err(failure) => show_failure(app, &failure)?,
            }

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("the window could not be built")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                if let Some(mut child) = app.state::<Sidecar>().0.lock().unwrap().take() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }
        });
}

/// Starts the release and blocks until it says where it listens.
fn start_sidecar(app: &tauri::App) -> Result<(Child, String), Failure> {
    let path = sidecar_path(app);
    let log_path = sidecar_log_path(app);
    let log = log_path.as_deref().and_then(open_log);

    let mut child = Command::new(&path)
        .arg("start")
        // The tool has no peers, so distribution buys it nothing and costs it
        // everything: a release node name is fixed, and a second launch — or a
        // sidecar left running by an earlier one — makes this one die with
        // "the name confluence_phx_mirror@host seems to be in use by another
        // Erlang node", which the shell can only report as a sidecar that never
        // said where it listens.
        .env("RELEASE_DISTRIBUTION", "none")
        .stdout(Stdio::piped())
        .stderr(stderr_for(&log))
        .spawn()
        .map_err(|error| Failure {
            message: format!("{} could not be started: {error}", path.display()),
            log: log_path.clone(),
        })?;

    let stdout = child.stdout.take().ok_or_else(|| Failure {
        message: "the release has no output to read".to_string(),
        log: log_path.clone(),
    })?;

    let mut reader = BufReader::new(stdout);
    let mut line = String::new();

    loop {
        line.clear();

        match reader.read_line(&mut line) {
            Ok(0) => {
                return Err(Failure {
                    message: "the release stopped before it said where it listens".to_string(),
                    log: log_path,
                })
            }
            Ok(_) => {}
            Err(error) => {
                return Err(Failure {
                    message: format!("the release's output could not be read: {error}"),
                    log: log_path,
                })
            }
        }

        if let Some(url) = line.trim().strip_prefix("desktop ui: ") {
            let url = url.to_string();

            // Whatever else it prints has to keep being read: a pipe nobody
            // drains fills up and blocks the process writing to it. It goes
            // where the person can find it, which is the log when there is one.
            let mut sink = log;

            std::thread::spawn(move || {
                for line in reader.lines().map_while(Result::ok) {
                    match &mut sink {
                        Some(file) => {
                            let _ = writeln!(file, "{line}");
                        }
                        None => println!("{line}"),
                    }
                }
            });

            return Ok((child, url));
        }
    }
}

/// Opens the window on the reason, instead of the process dying with it.
fn show_failure(app: &tauri::App, failure: &Failure) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(file) = failure.log.as_deref().and_then(open_log) {
        let mut file = file;
        let _ = writeln!(
            file,
            "the window could not start the release: {}",
            failure.message
        );
    }

    let window =
        WebviewWindowBuilder::new(app, "main", WebviewUrl::External("about:blank".parse()?))
            .title("Confluence Export did not start")
            .inner_size(760.0, 420.0)
            .min_inner_size(480.0, 300.0)
            .build()?;

    window.eval(failure_page(failure))?;
    Ok(())
}

/// What the window says: which step failed, and where the release's own log is.
/// The release's log is where the *cause* usually is — a migration that refused,
/// a database another copy holds — and it is a file precisely because a window
/// opened from Finder has no terminal to print to.
fn failure_page(failure: &Failure) -> String {
    let log = match &failure.log {
        Some(path) => format!("\n\nThe release writes its own log to:\n{}", path.display()),
        None => String::new(),
    };

    let text = escape_html(&format!(
        "Confluence Export could not start.\n\n{}{}",
        failure.message, log
    ));

    format!(
        "document.title = 'Confluence Export did not start';\
         document.body.style.margin = '0';\
         document.body.innerHTML = '<pre style=\"margin:0;padding:24px;\
         font:13px/1.6 -apple-system,system-ui;white-space:pre-wrap\">{text}</pre>';"
    )
}

fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The release's own output, in a file when there is one. A window opened from
/// Finder has no stderr to inherit into, so inheriting it loses exactly the
/// lines that explain a failure.
fn stderr_for(log: &Option<File>) -> Stdio {
    match log {
        Some(file) => match file.try_clone() {
            Ok(clone) => Stdio::from(clone),
            Err(_) => Stdio::inherit(),
        },
        None => Stdio::inherit(),
    }
}

/// `~/Library/Logs/<bundle id>/sidecar.log`, or nothing if macOS will not say.
fn sidecar_log_path(app: &tauri::App) -> Option<PathBuf> {
    app.path()
        .app_log_dir()
        .ok()
        .map(|directory| directory.join("sidecar.log"))
}

fn open_log(path: &Path) -> Option<File> {
    if let Some(directory) = path.parent() {
        std::fs::create_dir_all(directory).ok()?;
    }

    OpenOptions::new().create(true).append(true).open(path).ok()
}

fn sidecar_path(app: &tauri::App) -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("CONFLUENCE_EXPORT_SIDECAR") {
        return explicit.into();
    }

    // In a bundle the release travels inside Resources — `bundle.resources` in
    // tauri.conf.json puts it there — so this is the same layout with a
    // different parent. Asked first, because a window run from the checkout and
    // a window double-clicked from /Applications must not be able to disagree
    // about which release is behind them.
    if let Ok(resources) = app.path().resource_dir() {
        let bundled = resources.join("rel/confluence_phx_mirror/bin/confluence_phx_mirror");
        if bundled.exists() {
            return bundled;
        }
    }

    // Development: the release inside the checkout.
    "../_build/desktop/rel/confluence_phx_mirror/bin/confluence_phx_mirror".into()
}
