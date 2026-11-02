//! The window, and the sidecar behind it.
//!
//! Tauri is a window here, and a process supervisor, and nothing else. It starts
//! the Elixir release, reads the address that release prints, and points a
//! webview at it. Everything the tool does lives in the sidecar — the same
//! binary a headless machine would run — so the window adds no behaviour and
//! cannot drift from the server.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

/// The sidecar, kept so it can be stopped when the window goes away. A window
/// closed over a server still running is a port nobody can find again, holding
/// a database open.
struct Sidecar(Mutex<Option<Child>>);

fn main() {
    tauri::Builder::default()
        .manage(Sidecar(Mutex::new(None)))
        .setup(|app| {
            let (child, url) = start_sidecar()?;
            app.state::<Sidecar>().0.lock().unwrap().replace(child);

            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse()?))
                .title("Confluence Export")
                .inner_size(1024.0, 760.0)
                .min_inner_size(720.0, 560.0)
                .build()?;

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
fn start_sidecar() -> Result<(Child, String), Box<dyn std::error::Error>> {
    let path = sidecar_path();

    let mut child = Command::new(&path)
        .arg("start")
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| format!("{} could not be started: {error}", path.display()))?;

    let stdout = child.stdout.take().ok_or("the sidecar has no output to read")?;
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();

    loop {
        line.clear();

        if reader.read_line(&mut line)? == 0 {
            return Err("the sidecar stopped before it said where it listens".into());
        }

        if let Some(url) = line.trim().strip_prefix("desktop ui: ") {
            let url = url.to_string();

            // Whatever else it prints has to keep being read: a pipe nobody
            // drains fills up and blocks the process writing to it.
            std::thread::spawn(move || {
                for line in reader.lines().map_while(Result::ok) {
                    println!("{line}");
                }
            });

            return Ok((child, url));
        }
    }
}

fn sidecar_path() -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("CONFLUENCE_EXPORT_SIDECAR") {
        return explicit.into();
    }

    // Development: the release inside the checkout. A bundle puts the same
    // binary in Resources, which is this call with a different parent.
    "../_build/desktop/rel/confluence_phx_mirror/bin/confluence_phx_mirror".into()
}
