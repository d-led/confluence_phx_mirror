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

// A release build on Windows is a window, not a console program. Without this
// every launch opens a console beside the app — and a failure closes it again
// before the sentence on it can be read, which is what "a window that flashes
// and disappears" is. What a failure says goes to the log and to the failure
// page below.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

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

/// Why the release could not be started — as one of a few situations a person
/// can act on, not as whatever the release happened to print.
///
/// A failure is not exceptional: the release can refuse to boot (a catalogue
/// that belongs to another site, a folder another copy holds, a token the system
/// will not hand over), and it says why at length, in Elixir. That text is the
/// answer and it is unreadable to the person in front of the window. So the shell
/// keeps it — in the log, and behind "What the app said" — and leads with one
/// sentence, chosen by matching the release's own words. A panic here instead of
/// a value would unwind through AppKit's Apple Event dispatch, which macOS
/// reports as `Confluence Export quit unexpectedly`, with the one useful sentence
/// on a stderr a double-clicked app does not have.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Trouble {
    /// Another copy of the app is open on this folder.
    AlreadyRunning,
    /// The folder was mirrored from a different Confluence site.
    AnotherSite,
    /// Something else holds the catalogue file.
    FolderInUse,
    /// The system would not unlock the saved token.
    CredentialsLocked,
    /// The release ran and stopped before it was ready.
    Stopped,
    /// The release ran and never became ready.
    Slow,
    /// The release became ready but the window has nothing to point at.
    NotAnswering,
    /// No release where one should be: a broken or half-copied download.
    MissingRelease,
}

impl Trouble {
    /// The headline. Distinct per situation, so two different problems never
    /// arrive as the same sentence.
    fn title(self) -> &'static str {
        match self {
            Trouble::AlreadyRunning => "Confluence Export is already running",
            Trouble::AnotherSite => "This folder belongs to a different site",
            Trouble::FolderInUse => "The folder is in use",
            Trouble::CredentialsLocked => "The saved token could not be read",
            Trouble::Stopped => "Confluence Export stopped while starting",
            Trouble::Slow => "Confluence Export is taking longer than it should",
            Trouble::NotAnswering => "The window has nothing to show",
            Trouble::MissingRelease => "This copy of the app is incomplete",
        }
    }

    /// What to do about it, in one breath. No paths to files the person did not
    /// ask for, no exit codes, no Elixir.
    fn explain(self) -> &'static str {
        match self {
            Trouble::AlreadyRunning => {
                "Another copy has this folder open, and two copies would write the \
                 same catalogue. Close its window — the app quits with it — then open \
                 this one again."
            }
            Trouble::AnotherSite => {
                "The mirror in this folder was made for a different Confluence site, \
                 so it will not open here. Save the connection for this site, or \
                 choose another folder to work in."
            }
            Trouble::FolderInUse => {
                "Something else is holding the catalogue: another copy, a backup, or a \
                 synced folder. Wait a moment and open the app again."
            }
            Trouble::CredentialsLocked => {
                "Your system would not unlock the saved Confluence token. Unlock the \
                 login keychain — or the Credential Manager on Windows — and open the \
                 app again."
            }
            Trouble::Stopped => {
                "It stopped before it was ready. The log below says what it was doing; \
                 nothing in your folder was changed."
            }
            Trouble::Slow => {
                "Starting did not finish within a minute. That is usually a first launch \
                 after an upgrade, a very large catalogue, or a system dialog waiting \
                 for an answer. Quit and open it again."
            }
            Trouble::NotAnswering => {
                "The app started but its server did not answer. Quit and open it again; \
                 if it happens twice, the log below says why."
            }
            Trouble::MissingRelease => {
                "The program this app runs is missing from it. Download it again — an \
                 interrupted unzip or a partial copy is the usual cause."
            }
        }
    }

    /// Which situation the release's own output describes.
    ///
    /// Every marker is a sentence this repository prints (`Desktop.Application`,
    /// `Sites`, exqlite). Nothing else is matched: a wrong guess would name a
    /// cause the person cannot act on, which is worse than the general answer.
    fn classify(said: &VecDeque<String>) -> Self {
        let said = said
            .iter()
            .map(|line| line.to_lowercase())
            .collect::<Vec<_>>()
            .join("\n");

        let matches = |needle: &str| said.contains(needle);

        if matches("already running: another copy") {
            Trouble::AlreadyRunning
        } else if matches("belongs to the site") {
            Trouble::AnotherSite
        } else if matches("database busy") || matches("database is locked") {
            Trouble::FolderInUse
        } else if matches("keychain") || matches("credential store") || matches("secret service") {
            Trouble::CredentialsLocked
        } else {
            Trouble::Stopped
        }
    }
}

/// A failure, ready to be shown: the situation, and the log that explains it.
struct Failure {
    trouble: Trouble,
    log: Option<PathBuf>,
}

/// What the page is drawn from: the trouble, if there is one, and the release's
/// own last lines — kept for the log and for "What the app said", never for the
/// headline.
#[derive(Default)]
struct Shared {
    failed: Option<Failure>,
    output: VecDeque<String>,
}

type SharedState = Arc<Mutex<Shared>>;

/// A line of the release's output, kept in the log file and behind the page's
/// details. Forty is enough to hold a refusal and its reason.
const KEPT_LINES: usize = 40;

/// How long a launch may take before the window stops saying it is starting.
///
/// A first launch after an upgrade can migrate a large catalogue, and the system
/// can put a keychain question in front of the person at any point; both are
/// reasons to be patient. A minute is past all of them, and past the point where
/// a spinner is an answer.
const STARTUP_DEADLINE: std::time::Duration = std::time::Duration::from_secs(60);

/// How long the release may take to answer once it has said where it listens.
/// It has already started listening by then, so this is a formality that catches
/// a server that died between its first line and the first request.
const ANSWER_DEADLINE: std::time::Duration = std::time::Duration::from_secs(10);

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

    let mut command = launch_command(&path);

    command
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
        //
        // A pipe, not a signal, because it is the one mechanism that behaves the
        // same on all three platforms: closing the write end (a dead window's
        // handles are closed by the kernel) is end-of-file to the reader, and
        // Windows has no `SIGTERM` to send instead.
        .env("CONFLUENCE_EXPORT_DIE_WITH_PARENT", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    if !path.exists() {
        return Err(Failure {
            trouble: Trouble::MissingRelease,
            log: log_path,
        });
    }

    let mut child = command.spawn().map_err(|_error| Failure {
        // A launcher that exists and cannot run is a broken install, not a
        // misconfigured one: there is nothing a person can do but download it
        // again.
        trouble: Trouble::MissingRelease,
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
        trouble: Trouble::Stopped,
        log: log_path.clone(),
    })?;

    // Lines arrive on a channel rather than being read in this loop, because
    // waiting for one has to be able to stop waiting: a release that never says
    // where it listens — a lock it cannot get, a question nobody answered — used
    // to leave the window on "Starting…" for as long as the app stayed open.
    let (lines, arriving) = std::sync::mpsc::channel::<String>();

    {
        // The log file is handed to this reader: it is the one that outlives the
        // launch, and the other reader took its own handle above.
        let shared = Arc::clone(shared);
        std::thread::spawn(move || {
            let mut sink = Sink::new(log.as_ref(), shared);
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                sink.line(&line);
                // A closed receiver means the window gave up waiting; the
                // release is still drained so it never blocks on a full pipe.
                let _ = lines.send(line);
            }
        });
    }

    let started = std::time::Instant::now();

    loop {
        let left = STARTUP_DEADLINE.saturating_sub(started.elapsed());

        if left.is_zero() {
            return Err(Failure {
                trouble: Trouble::Slow,
                log: log_path,
            });
        }

        match arriving.recv_timeout(left) {
            Ok(line) => {
                if let Some(url) = line.trim().strip_prefix("desktop ui: ") {
                    return match answering(url) {
                        Ok(()) => Ok((child, url.to_string())),
                        Err(()) => Err(Failure {
                            trouble: Trouble::NotAnswering,
                            log: log_path,
                        }),
                    };
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                return Err(Failure {
                    trouble: Trouble::Slow,
                    log: log_path,
                })
            }
            // The release closed its output: it is gone, and the reason is in
            // what it last said.
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let trouble = Trouble::classify(&shared.lock().unwrap().output);
                return Err(Failure {
                    trouble,
                    log: log_path,
                });
            }
        }
    }
}

/// Waits for the address the release announced to accept a connection.
///
/// The window is pointed at this address, so navigating before it answers hands
/// a person the webview's own error page — a blank window with a technical
/// sentence in it. The release said where it listens from inside its listener,
/// so this normally succeeds on the first try; the wait is for the case where it
/// died in the microseconds between the line and the request.
fn answering(url: &str) -> Result<(), ()> {
    answering_within(url, ANSWER_DEADLINE)
}

fn answering_within(url: &str, within: std::time::Duration) -> Result<(), ()> {
    let address = url
        .trim_start_matches("http://")
        .split('/')
        .next()
        .unwrap_or_default()
        .to_string();

    let deadline = std::time::Instant::now() + within;

    loop {
        if std::net::TcpStream::connect(&address).is_ok() {
            return Ok(());
        }

        if std::time::Instant::now() > deadline {
            return Err(());
        }

        std::thread::sleep(std::time::Duration::from_millis(100));
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
    // Three sentences at three times, each saying something true: that it is
    // starting, that a slow first launch is normal, and — before the point where
    // `STARTUP_DEADLINE` turns this page into the failure page — that the wait
    // has a bound and the window will explain itself if it cannot start. A page
    // that says "starting" for ever is how a person is left guessing.
    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <title>Confluence Export</title>{STYLE}</head>\
         <body><main><div class=\"spinner\"></div>\
         <h1>Starting Confluence Export…</h1>\n         <p id=\"hint\">The app is starting its own server.</p></main>\
         <script>(function () {{\n           var hint = document.getElementById('hint');\n           setTimeout(function () {{\n             hint.textContent = 'Still starting. The first launch after an upgrade can take a while.';\n           }}, 5000);\n           setTimeout(function () {{\n             hint.textContent = 'This is taking longer than usual. If it cannot start, this window will say why.';\n           }}, 40000);\n         }})();</script></body></html>"
    )
}

/// What went wrong, in words the person in front of the window can act on.
///
/// The headline and the sentence come from `Trouble`; `output` is the release's
/// own text, folded behind a summary so it is available to whoever wants it and
/// out of the way of whoever does not.

/// What went wrong, in the release's own words.
///
/// The message says which step failed; `output` is where the *cause* usually is,
/// because an Elixir application that refuses to boot says why at length and then
/// exits without the window ever hearing an address — `this database belongs to
/// the site … but the mirror is configured for …` was one such refusal, and it is
/// the whole answer.
fn failure_page(failure: &Failure, output: &VecDeque<String>) -> String {
    // The release's own words, folded away. They are the answer for whoever is
    // debugging and noise for whoever is not, so the page leads with a sentence
    // and keeps the log one click behind it rather than in the person's face.
    let said = output
        .iter()
        .map(|line| escape_html(line))
        .collect::<Vec<_>>()
        .join("\n");

    let details = if said.trim().is_empty() {
        String::new()
    } else {
        format!("<details><summary>What the app said</summary><pre>{said}</pre></details>")
    };

    let log = match &failure.log {
        Some(path) => format!(
            "<p class=\"log\">The app's log has the whole of it: <code>{}</code></p>",
            escape_html(&path.display().to_string())
        ),
        None => String::new(),
    };

    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\">\
         <title>Confluence Export</title>{STYLE}</head>\
         <body><main><h1>{}</h1>\n         <p class=\"lead\">{}</p>\
         <p class=\"log\">Quit the app and open it again once that is dealt with.</p>\
         {details}{log}</main></body></html>",
        escape_html(failure.trouble.title()),
        escape_html(failure.trouble.explain())
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
  .log { opacity: .65; font-size: 13px; }
  details { margin: 22px 0 8px; }
  summary { cursor: pointer; font-size: 13px; opacity: .65; }
  summary:hover { opacity: .9; }
  pre { white-space: pre-wrap; word-break: break-word; font: 12px/1.5 ui-monospace, monospace;\
        background: color-mix(in srgb, CanvasText 6%, Canvas); padding: 14px 16px;\
        border-radius: 8px; max-height: 46vh; overflow: auto; }\
  .spinner { width: 22px; height: 22px; margin-bottom: 20px; border-radius: 50%;\
             border: 2px solid color-mix(in srgb, CanvasText 20%, Canvas);\
             border-top-color: CanvasText; animation: spin .9s linear infinite; }\
  @keyframes spin { to { transform: rotate(360deg); } }\
  @media (prefers-reduced-motion: reduce) { .spinner { animation-duration: 3s; } }\
</style>";

/// `~/Library/Logs/<bundle id>/sidecar.log` on macOS,
/// `~/.local/share/<bundle id>/logs/` on Linux, `%LOCALAPPDATA%\<bundle
/// id>\logs\` on Windows — Tauri resolves it per platform — or nothing if the
/// platform will not say.
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

/// The release's launcher inside its `bin/`, by platform.
///
/// A release ships `bin/confluence_phx_mirror` on Unix and
/// `bin/confluence_phx_mirror.bat` on Windows, where the `.bat` is what sets
/// the release's environment — and `CreateProcess` refuses to run a `.bat`
/// itself. `mix.exs` asks for both flavours (`include_executables_for`) so a
/// Windows build has the launcher it needs.
///
/// Directory and file are two names, joined one at a time. `join("bin/x.bat")`
/// keeps the forward slash inside the path; Windows accepts such a path in
/// `cmd`, and then `%~dp0` in the batch file carries that slash too, so the
/// release's launcher builds `…\bin/..\releases\0.1.0\start` and `erl` — which
/// does not normalise `…\bin/..` — answers **"cannot get boot file"**.
#[cfg(windows)]
const LAUNCHER_FILE: &str = "confluence_phx_mirror.bat";
#[cfg(not(windows))]
const LAUNCHER_FILE: &str = "confluence_phx_mirror";

const LAUNCHER_DIR: &str = "bin";

/// The command that starts the release.
///
/// On Windows that is `cmd /C call <the .bat>`: the launcher is not an
/// executable, and `call` is not decoration — an install under
/// `C:\Users\Dmitry Ledentsov\…` is a quoted path with a space in it, and `cmd`
/// on its own splits that at the first space. `CREATE_NO_WINDOW` keeps a console
/// from flashing up behind the app.
fn launch_command(path: &Path) -> Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;

        /// `CREATE_NO_WINDOW`, from `winbase.h`.
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;

        let mut command = Command::new("cmd");
        command
            .arg("/C")
            .arg("call")
            .arg(path)
            .creation_flags(CREATE_NO_WINDOW);
        command
    }

    #[cfg(not(windows))]
    {
        Command::new(path)
    }
}

fn sidecar_path(app: &AppHandle) -> PathBuf {
    if let Ok(explicit) = std::env::var("CONFLUENCE_EXPORT_SIDECAR") {
        return native(PathBuf::from(explicit));
    }

    // The release travels *inside* what was installed, and where that is depends
    // on the shape of the download:
    //
    //   * a macOS app bundle carries it in `Contents/Resources` — which is what
    //     `scripts/lib/bundle.sh` writes and what `resource_dir()` answers;
    //   * a Windows portable zip has no bundle at all, and `resource_dir()`
    //     answers the executable's own directory;
    //   * a Linux tarball is the same shape, but `resource_dir()` answers
    //     `../lib/<name>` (the Debian layout) — so the directory beside the
    //     executable has to be asked for by name.
    //
    // Both are asked, in that order, and the first that holds a launcher wins.
    // Getting this wrong is a window on nothing, which is why it is every
    // candidate and not a `cfg` branch.
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Ok(resources) = app.path().resource_dir() {
        candidates.push(bundled_release(&resources));
    }

    if let Some(directory) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
    {
        candidates.push(bundled_release(&directory));
    }

    candidates
        .into_iter()
        .find(|candidate| candidate.exists())
        // Development: the release inside the checkout.
        .unwrap_or_else(|| {
            native(
                PathBuf::from("..")
                    .join("_build")
                    .join("desktop")
                    .join("rel")
                    .join(RELEASE_DIR)
                    .join(LAUNCHER_DIR)
                    .join(LAUNCHER_FILE),
            )
        })
}

fn bundled_release(root: &Path) -> PathBuf {
    native(
        root.join("rel")
            .join(RELEASE_DIR)
            .join(LAUNCHER_DIR)
            .join(LAUNCHER_FILE),
    )
}

/// The release's own directory name: what `mix release` calls the folder.
const RELEASE_DIR: &str = "confluence_phx_mirror";

/// Every separator the platform's own, on Windows only.
///
/// The release's batch launchers pass their directory on to `erl`, which does
/// not normalise `…\bin/..` into `…` — and the release's directory name comes
/// from an environment variable that someone can write with slashes. On Unix a
/// path is already a path.
fn native(path: PathBuf) -> PathBuf {
    PathBuf::from(separators(&path.to_string_lossy(), cfg!(windows)))
}

fn separators(path: &str, windows: bool) -> String {
    if windows {
        path.replace('/', "\\")
    } else {
        path.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn said(lines: &[&str]) -> VecDeque<String> {
        lines.iter().map(|line| line.to_string()).collect()
    }

    // Every marker below is a sentence this repository actually prints. If one
    // of them is reworded, the classification quietly falls back to "it stopped"
    // — which is why the first three tests exist.
    #[test]
    fn a_second_copy_is_named_as_one() {
        let output = said(&[
            "22:41:02.100 [info] starting",
            "Confluence Export is already running: another copy of this app is",
            "answering on port 43100.",
        ]);

        assert_eq!(Trouble::classify(&output), Trouble::AlreadyRunning);
    }

    #[test]
    fn a_catalogue_another_process_holds_is_named_as_one() {
        let output = said(&["** (Exqlite.Error) Database busy"]);

        assert_eq!(Trouble::classify(&output), Trouble::FolderInUse);
    }

    #[test]
    fn a_folder_from_another_site_is_named_as_one() {
        let output = said(&["This database belongs to the site \"other\""]);

        assert_eq!(Trouble::classify(&output), Trouble::AnotherSite);
    }

    #[test]
    fn a_token_the_system_will_not_hand_over_is_named_as_one() {
        let output = said(&["could not read the item from the keychain"]);

        assert_eq!(Trouble::classify(&output), Trouble::CredentialsLocked);
    }

    #[test]
    fn an_unknown_failure_stays_general_rather_than_guessing() {
        let output = said(&["** (RuntimeError) something nobody wrote a sentence for"]);

        assert_eq!(Trouble::classify(&output), Trouble::Stopped);
    }

    #[test]
    fn every_situation_says_something_its_own() {
        let troubles = [
            Trouble::AlreadyRunning,
            Trouble::AnotherSite,
            Trouble::FolderInUse,
            Trouble::CredentialsLocked,
            Trouble::Stopped,
            Trouble::Slow,
            Trouble::NotAnswering,
            Trouble::MissingRelease,
        ];

        let titles: std::collections::HashSet<_> = troubles.iter().map(|t| t.title()).collect();
        let sentences: std::collections::HashSet<_> =
            troubles.iter().map(|t| t.explain()).collect();

        assert_eq!(
            titles.len(),
            troubles.len(),
            "two problems share a headline"
        );
        assert_eq!(
            sentences.len(),
            troubles.len(),
            "two problems share a sentence"
        );
    }

    #[test]
    fn the_failure_page_leads_with_a_sentence_and_folds_the_log() {
        let failure = Failure {
            trouble: Trouble::AlreadyRunning,
            log: None,
        };

        let page = failure_page(&failure, &said(&["** (exit) an Erlang crash term"]));

        assert!(page.contains(Trouble::AlreadyRunning.title()));
        assert!(page.contains(Trouble::AlreadyRunning.explain()));
        // Folded, not gone: the log is one click away and not in the person's
        // face.
        assert!(page.contains("<details><summary>What the app said</summary>"));
        assert!(page.contains("an Erlang crash term"));
    }

    #[test]
    fn a_page_with_nothing_said_has_no_empty_fold() {
        let failure = Failure {
            trouble: Trouble::Slow,
            log: None,
        };

        let page = failure_page(&failure, &VecDeque::new());

        assert!(!page.contains("<details>"));
        assert!(page.contains(Trouble::Slow.title()));
    }

    #[test]
    fn the_launch_checks_the_address_it_announced() {
        // Nothing listens on this port, so the answer must be "no" and the
        // window must not be pointed at it.
        assert_eq!(
            answering_within("http://127.0.0.1:1/", std::time::Duration::from_millis(50)),
            Err(())
        );
    }

    #[test]
    fn an_address_that_answers_is_accepted() {
        // The release's own shape of announcement: bind, then be asked.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a loopback port");
        let port = listener.local_addr().expect("an address").port();

        assert_eq!(
            answering_within(
                &format!("http://127.0.0.1:{port}/"),
                std::time::Duration::from_millis(500)
            ),
            Ok(())
        );
    }

    #[test]
    fn the_launcher_is_inside_the_release_and_named_per_platform() {
        let path = bundled_release(Path::new("/opt/confluence-export"));
        let parts: Vec<_> = path
            .components()
            .map(|part| part.as_os_str().to_string_lossy().into_owned())
            .collect();

        assert!(parts.ends_with(&[
            "rel".to_string(),
            RELEASE_DIR.to_string(),
            LAUNCHER_DIR.to_string(),
            LAUNCHER_FILE.to_string(),
        ]));
    }

    #[test]
    fn a_windows_path_carries_no_forward_slash_for_erl_to_choke_on() {
        // The batch launcher hands its own directory to `erl`, and `erl` does not
        // normalise `…\bin/..`: a slash left in the path is "cannot get boot
        // file" on a machine nobody can debug from here.
        assert_eq!(
            separators(r"C:\Users\me\rel\confluence_phx_mirror\bin/..\start", true),
            r"C:\Users\me\rel\confluence_phx_mirror\bin\..\start"
        );
    }

    #[test]
    fn a_unix_path_is_left_exactly_as_it_was() {
        assert_eq!(
            separators("/opt/rel/bin/start", false),
            "/opt/rel/bin/start"
        );

        // A resolver path that means something to the shell must not be rewritten
        // by a helper that only exists for Windows.
        assert_eq!(separators(r"C:\a\b", false), r"C:\a\b");
    }
}
