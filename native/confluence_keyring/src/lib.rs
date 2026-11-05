//! The OS credential store, for the desktop export tool.
//!
//! One generic-password item per workspace, keyed by a service name and the
//! workspace id. The `keyring` crate picks the platform's own store: the Apple
//! Keychain, Windows Credential Manager, or the Secret Service on Linux. The
//! secret is never on a filesystem this application controls, and never on a
//! command line where `ps` could read it.
//!
//! A missing entry is `Ok(None)`, not an error: asking for a credential that was
//! never stored is an ordinary answer, and the caller decides what it means.

use keyring::Entry;
use rustler::types::atom;

fn entry(service: String, account: String) -> Result<Entry, String> {
    Entry::new(&service, &account).map_err(|error| error.to_string())
}

/// Stores `secret` for `account`, replacing any earlier one.
///
/// Answers the atom `:ok` rather than Rust's unit type: `()` crosses into Elixir
/// as `{}`, which no caller wants to match on.
#[rustler::nif]
fn put_password(service: String, account: String, secret: String) -> Result<atom::Atom, String> {
    entry(service, account)?
        .set_password(&secret)
        .map_err(|error| error.to_string())?;

    Ok(atom::ok())
}

/// The secret stored for `account`, or `nil` when there is none.
#[rustler::nif]
fn get_password(service: String, account: String) -> Result<Option<String>, String> {
    match entry(service, account)?.get_password() {
        Ok(secret) => Ok(Some(secret)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

/// Forgets the secret stored for `account`. A missing entry is not an error.
#[rustler::nif]
fn delete_password(service: String, account: String) -> Result<atom::Atom, String> {
    match entry(service, account)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(atom::ok()),
        Err(error) => Err(error.to_string()),
    }
}

rustler::init!("Elixir.ConfluencePhxMirror.Desktop.Credentials.Keyring");
