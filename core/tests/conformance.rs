//! Protocol conformance harness.
//!
//! Drives the built `bureaucratpdf-core` binary over its line-delimited JSON
//! protocol and asserts the response *shapes* match the shared contract in
//! `../protocol`. Runs on every platform in CI (macos-latest + windows-latest)
//! so the two shells cannot silently desync (see design D7).
//!
//! Golden fixtures live in `protocol/vectors/`:
//!   - `test-signer.der`     throwaway self-signed cert (public only)
//!   - `sample-unsigned.pdf` a small unsigned PDF
//!
//! `prepare` needs only the *public* cert chain + the PDF (no private key), so
//! its response shape is fully reproducible without any secret material.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// Repo root = crate dir (`core/`) parent.
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn vectors_dir() -> PathBuf {
    repo_root().join("protocol").join("vectors")
}

/// Send one request line to the core, return the parsed one-line JSON response.
fn roundtrip(req: &Value) -> Value {
    let bin = env!("CARGO_BIN_EXE_bureaucratpdf-core");
    let mut child = Command::new(bin)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn core");
    let mut line = serde_json::to_vec(req).unwrap();
    line.push(b'\n');
    child.stdin.take().unwrap().write_all(&line).unwrap();
    let out = child.wait_with_output().expect("core output");
    let text = String::from_utf8(out.stdout).expect("utf8");
    let first = text.lines().next().expect("at least one response line");
    serde_json::from_str(first).expect("response is valid JSON")
}

#[test]
fn ping_exact() {
    let resp = roundtrip(&json!({"op": "ping"}));
    assert_eq!(resp, json!({"status": "ok", "pong": true}));
}

#[test]
fn prepare_need_signature_shape() {
    let der = std::fs::read(vectors_dir().join("test-signer.der"))
        .expect("test-signer.der fixture present");
    let pdf = vectors_dir().join("sample-unsigned.pdf");
    let work = std::env::temp_dir().join("plc-conformance-prepare");
    std::fs::create_dir_all(&work).unwrap();

    let req = json!({
        "op": "prepare",
        "pdf": pdf.to_str().unwrap(),
        "cert_chain": [B64.encode(&der)],
        "placements": [],
        "work_dir": work.to_str().unwrap(),
    });
    let resp = roundtrip(&req);

    assert_eq!(resp["status"], "need_signature", "got: {resp}");
    for k in ["status", "handle", "digest", "sig_alg"] {
        assert!(resp.get(k).is_some(), "missing field `{k}` in {resp}");
    }
    let alg = resp["sig_alg"].as_str().unwrap();
    assert!(
        alg == "rsa-pkcs1-sha256" || alg == "ecdsa-sha256",
        "unexpected sig_alg: {alg}"
    );
    // digest must be valid base64.
    B64.decode(resp["digest"].as_str().unwrap())
        .expect("digest is base64");
}

#[test]
fn verify_unsigned_reports_no_signature() {
    // The core's contract for an unsigned PDF is an explicit error, not an empty
    // signatures array — the shell surfaces "no signature found" to the user.
    let pdf = vectors_dir().join("sample-unsigned.pdf");
    let resp = roundtrip(&json!({"op": "verify", "pdf": pdf.to_str().unwrap()}));
    assert_eq!(resp["status"], "error", "got: {resp}");
    assert_eq!(resp["code"], "NO_SIGNATURE", "got: {resp}");
}

#[test]
fn bad_request_is_error() {
    let resp = roundtrip(&json!({"op": "nonexistent"}));
    assert_eq!(resp["status"], "error", "got: {resp}");
    assert!(resp.get("code").is_some());
}
