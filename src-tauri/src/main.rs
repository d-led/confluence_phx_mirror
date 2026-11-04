//! The window, and the sidecar behind it.
//!
//! Tauri is a window here, and a process supervisor, and nothing else. It starts
//! the Elixir release, reads the address that release prints, and points a
//! webview at it. Everything the tool does lives in the sidecar — the same
//! binary a headless machine would run — so the window adds no behaviour and
//! cannot drift from the server.
//!
//! What the window *does* owe a person is honesty while that happens. So it is
//! on screen before the release is started, showing a page that says so, and it
//! turns into that page's failure state — the reason, and the release's own last
//! words — when the release refuses to come up.

use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

/// The sidecar, kept so it can be stopped when the window goes away. A window
/// closed over a server still running is a port nobody can find again, holding
/// a database open.
struct Sidecar(Mutex<Option<Child>>);

/// Why the release could not be started.
///
/// A failure is not exceptional — the file can be missing, the release can
/// refuse to boot (a catalogue that belongs to another site, a database another
/// copy holds) — so it is a value, not a panic. A panic in `setup` unwinds
/// through AppKit's Apple Event dispatch, which macOS reports as `Confluence
/// Export quit unexpectedly`, with the one useful sentence on a stderr that a
/// double-clicked app does not have.
struct Failure {
    message: String,
    log: Option<PathBuf>,
}

/// What the page is drawn from: why it failed, if it did, and the release's own
/// last lines. The lines are the *reason* when the release refuses to boot — an
/// Elixir application that will not start says why, at length, and then exits
/// without the window ever hearing an address.
#[derive(Default)]
struct Shared {
    failed: Option<Failure>,
    output: VecDeque<String>,
}

type SharedState = Arc<Mutex<Shared>>;

/// A line of the release's output, kept in the log file and in the page.
const KEPT_LINES: usize = 40;

/// The scheme the waiting page is served from. A custom protocol rather than
/// `about:blank`, because `about:blank` has no document to write into when the
/// window opens and an `eval` against it silently does nothing — which is how a
/// failure page reached a person as an empty window.
const SPLASH: &str = "splash";

fn main() {
    let shared: SharedState = Arc::new(Mutex::new(Shared::default()));

    tauri::Builder::default()
        .manage(Sidecar(Mutex::new(None)))
        .register_uri_scheme_protocol(SPLASH, {
            let shared = Arc::clone(&shared);

            move |_app, _request| {
                let page = startup_page(&shared.lock().unwrap());

                tauri::http::Response::builder()
                    .header("Content-Type", "text/html; charset=utf-8")
                    .body(std::borrow::Cow::Owned(page.into_bytes()))
                    .expect("a page built here is a valid response")
            }
        })
        .setup(move |app| {
            // Built first, pointed at the waiting page: `setup` used to block
            // until the release had spoken, so a slow boot was a window that did
            // not exist and a failed one was no window at all.
            let window = splash_window(app)?;
            let handle = app.handle().clone();
            let shared = Arc::clone(&shared);

            std::thread::spawn(move || match start_sidecar(&handle, &shared) {
                Ok((child, url)) => {
                    handle.state::<Sidecar>().0.lock().unwrap().replace(child);
                    navigate(&window, &url);
                }
                Err(failure) => {
                    if let Ok(mut state) = shared.lock() {
                        state.failed = Some(failure);
                    }

                    // The same page, asked for again: what it serves is read
                    // from the state above, so this swap is the whole redraw.
                    navigate(&window, &format!("{SPLASH}://localhost/?failed=1"));
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("the window could not be built")
        .run(|app, event| match event {
            // There is no tray icon and no menu of ours: a window nobody can see
            // is an app nobody can quit, still holding the port the next launch
            // wants. Closing the window closes the app.
            tauri::RunEvent::WindowEvent {
                label,
                event: tauri::WindowEvent::Destroyed,
                ..
            } if label == "main" => app.exit(0),

            tauri::RunEvent::Exit => {
                if let Some(mut child) = app.state::<Sidecar>().0.lock().unwrap().take() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
            }

            _ => {}
        });
}

fn splash_window(app: &tauri::App) -> Result<WebviewWindow, Box<dyn std::error::Error>> {
    let url: tauri::Url = format!("{SPLASH}://localhost/").parse()?;

    Ok(
        WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url))
            .title("Confluence Export")
            .inner_size(1024.0, 760.0)
            .min_inner_size(720.0, 560.0)
            .build()?,
    )
}

fn navigate(window: &WebviewWindow, url: &str) {
    if let Ok(url) = url.parse::<tauri::Url>() {
        let _ = window.navigate(url);
    }
}

/// Starts the release and blocks this thread until it says where it listens.
fn start_sidecar(app: &AppHandle, shared: &SharedState) -> Result<(Child, String), Failure> {
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
        // The release watches this pipe and stops when it closes: a window that
        // was force-quit or killed never gets to ask its sidecar to stop, and a
        // server left holding the port is a launch that cannot have it. Only set
        // for a window — a release started from a shell inherits a stdin that may
        // already be at end-of-file, and must not exit over it.
        .env("CONFLUENCE_EXPORT_DIE_WITH_PARENT", "1")
        // A pipe the window owns: when this process dies, the write end closes
        // and the release sees end-of-file. That is the only signal a killed
        // window can still send.
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| Failure {
            message: format!("{} could not be started: {error}", path.display()),
            log: log_path.clone(),
        })?;

    // Both halves of what the release says are read, and both go where a person
    // can find them: the log file, and the page that will explain the failure.
    // A pipe nobody drains also fills up and blocks the process writing to it.
    if let Some(stderr) = child.stderr.take() {
        let mut sink = Sink::new(log.as_ref(), Arc::clone(shared));
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                sink.line(&line);
            }
        });
    }

    let stdout = child.stdout.take().ok_or_else(|| Failure {
        message: "the release has no output to read".to_string(),
        log: log_path.clone(),
    })?;

    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let mut early = Sink::new(log.as_ref(), Arc::clone(shared));

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

        match line.trim().strip_prefix("desktop ui: ") {
            Some(url) => {
                let url = url.to_string();
                let mut sink = early;

                std::thread::spawn(move || {
                    for line in reader.lines().map_while(Result::ok) {
                        sink.line(&line);
                    }
                });

                return Ok((child, url));
            }
            None => early.line(line.trim_end()),
        }
    }
}

/// The release's output as the page will show it, and as the log file keeps it.
struct Sink {
    log: Option<File>,
    shared: SharedState,
}

impl Sink {
    fn new(log: Option<&File>, shared: SharedState) -> Self {
        Self {
            log: log.and_then(|file| file.try_clone().ok()),
            shared,
        }
    }

    fn line(&mut self, line: &str) {
        if let Some(file) = &mut self.log {
            let _ = writeln!(file, "{line}");
        }

        if let Ok(mut shared) = self.shared.lock() {
            if shared.output.len() == KEPT_LINES {
                shared.output.pop_front();
            }

            shared.output.push_back(line.to_string());
        }
    }
}

/// The page the window is on from the moment it opens: what is happening, or
/// what went wrong. Served from the `splash://` scheme so the window has a real
/// document to show before there is a server to point it at.
fn startup_page(shared: &Shared) -> String {
    match &shared.failed {
        Some(failure) => failure_page(failure, &shared.output),
        None => waiting_page(),
    }
}

fn waiting_page() -> String {
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <title>Confluence Export</title>{STYLE}</head>\
         <body><main><div class=\"spinner\"></div>\
         <h1>Starting Confluence Export…</h1>\n         <p id=\"hint\">The mirror is starting its own server.</p></main>\
         <script>setTimeout(function () {{\n           document.getElementById('hint').textContent =\n             'Still starting. The first launch after an upgrade can take a few seconds.';\n         }}, 5000);</script></body></html>"
    )
}

/// What went wrong, in the release's own words.
///
/// The message says which step failed; `output` is where the *cause* usually is,
/// because an Elixir application that refuses to boot says why at length and then
/// exits without the window ever hearing an address — `this database belongs to
/// the site … but the mirror is configured for …` was one such refusal, and it is
/// the whole answer.
fn failure_page(failure: &Failure, output: &VecDeque<String>) -> String {
    let said = output
        .iter()
        .map(|line| escape_html(line))
        .collect::<Vec<_>>()
        .join("\n");

    let log = match &failure.log {
        Some(path) => format!(
            "<p class=\"log\">The release's log, with everything it printed: <code>{}</code></p>",
            escape_html(&path.display().to_string())
        ),
        None => String::new(),
    };

    let said = if said.is_empty() {
        String::new()
    } else {
        format!("<h2>What the release said</h2><pre>{said}</pre>")
    };

    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <title>Confluence Export</title>{STYLE}</head>\
         <body><main><h1>Confluence Export could not start</h1>\n         <p class=\"lead\">{}</p>{said}{log}\n         <p class=\"log\">Quit and open it again once that is dealt with.</p></main></body></html>",
        escape_html(&failure.message)
    )
}

/// Everything a page in this window shows is text from somewhere else, so the
/// one thing it must not do is paste it in as markup.
fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

const STYLE: &str = "<style>\
  :root { color-scheme: light dark; }\
  body { margin: 0; font: 14px/1.6 -apple-system, system-ui;\
         background: Canvas; color: CanvasText; }\
  main { padding: 40px 44px; max-width: 820px; }\
  h1 { font-size: 19px; margin: 0 0 10px; }\
  h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em;\
       opacity: .55; margin: 26px 0 8px; }\
  .lead { margin: 0 0 4px; }\
  .log { opacity: .65; font-size: 13px; }\
  pre { white-space: pre-wrap; word-break: break-word; font: 12px/1.5 ui-monospace, monospace;\
        background: color-mix(in srgb, CanvasText 6%, Canvas); padding: 14px 16px;\
        border-radius: 8px; max-height: 46vh; overflow: auto; }\
  .spinner { width: 22px; height: 22px; margin-bottom: 20px; border-radius: 50%;\
             border: 2px solid color-mix(in srgb, CanvasText 20%, Canvas);\
             border-top-color: CanvasText; animation: spin .9s linear infinite; }\
  @keyframes spin { to { transform: rotate(360deg); } }\
  @media (prefers-reduced-motion: reduce) { .spinner { animation-duration: 3s; } }\
</style>";

/// `~/Library/Logs/<bundle id>/sidecar.log`, or nothing if macOS will not say.
fn sidecar_log_path(app: &AppHandle) -> Option<PathBuf> {
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

fn sidecar_path(app: &AppHandle) -> PathBuf {
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
