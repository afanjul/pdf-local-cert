use serde::{Deserialize, Serialize};

/// One placement of a visible signature on a page.
#[derive(Debug, Clone, Deserialize)]
pub struct Placement {
    pub page: u32,
    /// PDF user-space rect: lower-left x,y and width,height (points).
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    /// Text lines to render in the box (already composed by shell or here).
    #[serde(default)]
    pub lines: Vec<String>,
    /// Optional pre-rendered appearance image (raw RGBA8, top row first).
    /// When present, the box is drawn from this image instead of text.
    #[serde(default)]
    pub image: Option<AppearanceImage>,
}

/// A flattened appearance bitmap rendered by the shell (so on-screen preview is
/// byte-identical to the embedded result). `rgba_path` points at a raw RGBA8
/// buffer of `width`×`height` pixels, rows top-to-bottom.
#[derive(Debug, Clone, Deserialize)]
pub struct AppearanceImage {
    pub rgba_path: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op")]
pub enum Request {
    #[serde(rename = "prepare")]
    Prepare(PrepareReq),
    #[serde(rename = "finalize")]
    Finalize(FinalizeReq),
    #[serde(rename = "verify")]
    Verify(VerifyReq),
    #[serde(rename = "ping")]
    Ping,
}

#[derive(Debug, Deserialize)]
pub struct PrepareReq {
    /// Path to input PDF.
    pub pdf: String,
    /// Cert chain, signer first, each DER base64.
    pub cert_chain: Vec<String>,
    /// Empty = invisible signature.
    #[serde(default)]
    pub placements: Vec<Placement>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub location: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    /// RFC 3161 TSA URL. None/empty = B-B only.
    #[serde(default)]
    pub tsa_url: Option<String>,
    /// Working dir for state + output.
    pub work_dir: String,
}

#[derive(Debug, Serialize)]
pub struct PrepareResp {
    pub status: String, // "need_signature"
    pub handle: String,
    /// SHA-256 digest of SignedAttributes, base64. Shell signs THIS.
    pub digest: String,
    /// "rsa-pkcs1-sha256" | "ecdsa-sha256"
    pub sig_alg: String,
}

#[derive(Debug, Deserialize)]
pub struct FinalizeReq {
    pub handle: String,
    /// Raw signature bytes, base64.
    pub signature: String,
}

#[derive(Debug, Serialize)]
pub struct FinalizeResp {
    pub status: String, // "ok"
    pub out: String,
    pub pades_level: String, // "B-B" | "B-T"
    pub signer_cn: String,
}

#[derive(Debug, Deserialize)]
pub struct VerifyReq {
    pub pdf: String,
}

#[derive(Debug, Serialize)]
pub struct VerifyResp {
    pub status: String, // "ok"
    pub signatures: Vec<SigInfo>,
}

#[derive(Debug, Serialize)]
pub struct SigInfo {
    pub valid: bool,
    pub signer_cn: String,
    pub issuer_cn: String,
    pub signing_time: Option<String>,
    pub has_timestamp: bool,
    pub pades_level: String,
    pub byte_range_covers_whole_file: bool,
    pub detail: String,
}

#[derive(Debug, Serialize)]
pub struct ErrResp {
    pub status: String, // "error"
    pub code: String,
    pub message: String,
}

impl ErrResp {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        ErrResp { status: "error".into(), code: code.into(), message: message.into() }
    }
}
