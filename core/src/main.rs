//! bureaucratpdf-core — signing sidecar for Bureaucrat PDF.
//!
//! Speaks a line-delimited JSON protocol on stdin/stdout. One request per line,
//! one response per line. The private key never reaches this process: `prepare`
//! returns a digest, the Swift shell signs it via the Keychain, and `finalize`
//! assembles the CMS with the returned signature (external/callback signer).

mod protocol;
mod sign;
mod cms;
mod tsa;
mod verify;

use protocol::*;
use std::io::{BufRead, Write};

fn main() {
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) if !l.trim().is_empty() => l,
            Ok(_) => continue,
            Err(_) => break,
        };
        let resp = dispatch(&line);
        writeln!(out, "{resp}").ok();
        out.flush().ok();
    }
}

fn dispatch(line: &str) -> String {
    let req: Request = match serde_json::from_str(line) {
        Ok(r) => r,
        Err(e) => return err("BAD_REQUEST", format!("invalid JSON: {e}")),
    };

    match req {
        Request::Ping => r#"{"status":"ok","pong":true}"#.to_string(),
        Request::Prepare(p) => match sign::prepare(p) {
            Ok(r) => json(&r),
            Err(e) => err(&e.0, e.1),
        },
        Request::Finalize(f) => match sign::finalize(f) {
            Ok(r) => json(&r),
            Err(e) => err(&e.0, e.1),
        },
        Request::Verify(v) => match verify::verify(v) {
            Ok(r) => json(&r),
            Err(e) => err(&e.0, e.1),
        },
    }
}

fn json<T: serde::Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap_or_else(|e| err("ENCODE", e.to_string()))
}

fn err(code: &str, msg: impl Into<String>) -> String {
    serde_json::to_string(&ErrResp::new(code, msg)).unwrap()
}

/// Error pair: (code, message).
pub type CoreErr = (String, String);
pub fn cerr(code: &str, msg: impl Into<String>) -> CoreErr {
    (code.to_string(), msg.into())
}
