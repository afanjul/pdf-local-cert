//! PDF signature surgery: incremental update, /ByteRange, /Contents placeholder.
//!
//! `prepare` appends a signature dictionary + widget + AcroForm via an
//! incremental update, computes the byte range, and returns the SignedAttributes
//! to be signed. `finalize` splices the assembled CMS into the placeholder.

use crate::cms::{self, KeyKind};
use crate::protocol::*;
use crate::tsa;
use crate::{cerr, CoreErr};
use base64::Engine;
use lopdf::{Document, Object};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

const CONTENTS_HEX_LEN: usize = 32768; // 16 KB of signature room
const BR_FIELD_W: usize = 10;

fn b64() -> base64::engine::general_purpose::GeneralPurpose {
    base64::engine::general_purpose::STANDARD
}

#[derive(serde::Serialize, serde::Deserialize)]
struct State {
    working_pdf: String,
    contents_start: usize,
    signed_attrs_b64: String,
    chain_b64: Vec<String>,
    kind: String, // "rsa" | "ecdsa"
    tsa_url: Option<String>,
    signer_cn: String,
    out_path: String,
}

// ---------- prepare ----------

pub fn prepare(req: PrepareReq) -> Result<PrepareResp, CoreErr> {
    let raw = std::fs::read(&req.pdf).map_err(|e| cerr("BAD_PDF", format!("read: {e}")))?;
    let mut doc = Document::load_mem(&raw)
        .map_err(|e| cerr("BAD_PDF", format!("parse: {e}")))?;

    if doc.is_encrypted() {
        return Err(cerr("PDF_ENCRYPTED", "document is encrypted"));
    }

    // Normalize the base PDF before the first signature.
    //
    // Some source PDFs ship a corrupt cross-reference table — e.g. phantom xref
    // entries with generation 65536 pointing at offset 0 for objects that do not
    // exist in the body. Lenient validators (DSS / BouncyCastle) silently repair
    // such files and report the signature as valid, but Adobe Acrobat walks the
    // xref strictly: a signature laid over a document Acrobat had to repair shows
    // up as "An error occurred while attempting to validate this signature".
    // Acrobat itself sidesteps this by fully rewriting the document when it signs
    // (its output is a clean PDF with regenerated xref).
    //
    // We do the same: for an UNSIGNED document we round-trip through lopdf to emit
    // a clean, valid xref table and then sign that normalized base via incremental
    // update. We skip this when the document already carries a signature (detected
    // by a `/ByteRange` entry), because rewriting the base bytes would break the
    // byte ranges — and thus the validity — of any existing signature.
    let bytes = if has_existing_signature(&raw) {
        raw
    } else {
        match normalize_pdf(&mut doc) {
            Some(clean) => {
                doc = Document::load_mem(&clean)
                    .map_err(|e| cerr("BAD_PDF", format!("reparse normalized: {e}")))?;
                clean
            }
            None => raw, // normalization failed: fall back to the original bytes
        }
    };

    let chain: Vec<Vec<u8>> = req
        .cert_chain
        .iter()
        .map(|s| b64().decode(s).map_err(|e| cerr("BAD_REQUEST", format!("cert b64: {e}"))))
        .collect::<Result<_, _>>()?;
    if chain.is_empty() {
        return Err(cerr("BAD_REQUEST", "empty cert chain"));
    }
    let signer_der = &chain[0];
    let (kind, signer_cn) =
        cms::inspect_cert(signer_der).map_err(|e| cerr("BAD_REQUEST", e))?;

    let catalog_ref = match doc.trailer.get(b"Root") {
        Ok(Object::Reference(r)) => *r,
        _ => return Err(cerr("BAD_PDF", "no /Root reference")),
    };
    let info_ref = match doc.trailer.get(b"Info") {
        Ok(Object::Reference(r)) => Some(*r),
        _ => None,
    };

    let pages = doc.get_pages();
    let target_page = req.placements.first().map(|p| p.page).unwrap_or(1);
    let page_ref = *pages
        .get(&target_page)
        .or_else(|| pages.get(&1))
        .ok_or_else(|| cerr("BAD_PDF", "no pages"))?;

    let prev_startxref = last_startxref(&bytes)
        .ok_or_else(|| cerr("BAD_PDF", "no startxref"))?;

    let max_id = doc.max_id;
    let sig_id = max_id + 1;
    let annot_id = max_id + 2;
    let mut next_id = max_id + 3;

    let visible = !req.placements.is_empty();
    let placement = req.placements.first();
    let multi = req.placements.len() > 1;

    let mut new_objects: Vec<(u32, u16, Vec<u8>)> = Vec::new();
    let mut rewrites: Vec<(u32, u16, Vec<u8>)> = Vec::new();

    // Signature dictionary (ByteRange placeholder filled with zeros, patched later).
    // Shared by single and multi paths.
    let zeros = "0".repeat(BR_FIELD_W);
    let contents_placeholder = "0".repeat(CONTENTS_HEX_LEN);
    let signer_name = req.name.clone().unwrap_or_else(|| signer_cn.clone());
    let reason_clause = req
        .reason
        .as_ref()
        .map(|r| format!(" /Reason ({})", escape_pdf_text(r)))
        .unwrap_or_default();
    let location_clause = req
        .location
        .as_ref()
        .map(|l| format!(" /Location ({})", escape_pdf_text(l)))
        .unwrap_or_default();
    let sig_dict = format!(
        "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /ETSI.CAdES.detached \
/Name ({name}) /M ({date}){reason_clause}{location_clause} \
/ByteRange [0 {zeros} {zeros} {zeros}] /Contents <{contents_placeholder}> >>",
        name = escape_pdf_text(&signer_name),
        date = now_pdf_date(),
    );
    new_objects.push((sig_id, 0, object_block(sig_id, 0, sig_dict.as_bytes())));

    let catalog = doc
        .get_object(catalog_ref)
        .and_then(|o| o.as_dict())
        .map_err(|e| cerr("BAD_PDF", format!("catalog: {e}")))?
        .clone();

    if multi {
        // One signature field with N widget kids (same /V), one per placement.
        let field_id = next_id;
        next_id += 1;
        let mut kids: Vec<u32> = Vec::new();
        let mut by_page: std::collections::BTreeMap<(u32, u16), Vec<u32>> = Default::default();

        for p in &req.placements {
            let pr = *pages.get(&p.page).or_else(|| pages.get(&1))
                .ok_or_else(|| cerr("BAD_PDF", "no pages"))?;
            let ap_clause = build_appearance(p, &req, &signer_cn, &mut next_id, &mut new_objects)?;
            let wid = next_id;
            next_id += 1;
            let rect = format!("[{} {} {} {}]", p.x, p.y, p.x + p.w, p.y + p.h);
            let annot = format!(
                "<< /Type /Annot /Subtype /Widget /Parent {field_id} 0 R /P {pr_id} 0 R \
/Rect {rect} /F 4{ap_clause} >>",
                pr_id = pr.0
            );
            new_objects.push((wid, 0, object_block(wid, 0, annot.as_bytes())));
            kids.push(wid);
            by_page.entry(pr).or_default().push(wid);
        }

        let kids_str = kids.iter().map(|k| format!("{k} 0 R")).collect::<Vec<_>>().join(" ");
        let field = format!(
            "<< /FT /Sig /T (Signature1) /V {sig_id} 0 R /Kids [{kids_str}] >>"
        );
        new_objects.push((field_id, 0, object_block(field_id, 0, field.as_bytes())));

        add_field_to_acroform(&doc, &catalog, catalog_ref, field_id, &mut next_id, &mut new_objects, &mut rewrites)?;
        for (pr, ids) in by_page {
            add_widgets_to_page(&doc, pr, &ids, &mut rewrites)?;
        }
    } else {
        // Single visible (or invisible) signature: the annotation is also the field.
        let ap_clause = if visible {
            build_appearance(placement.unwrap(), &req, &signer_cn, &mut next_id, &mut new_objects)?
        } else {
            String::new()
        };

        let rect = if let Some(p) = placement {
            format!("[{} {} {} {}]", p.x, p.y, p.x + p.w, p.y + p.h)
        } else {
            "[0 0 0 0]".to_string()
        };
        let flags = if visible { 4 } else { 2 }; // Print / Hidden
        let field_name = "Signature1";
        let annot = format!(
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T ({field_name}) /V {sig_id} 0 R \
/P {pr_id} 0 R /Rect {rect} /F {flags}{ap_clause} >>",
            pr_id = page_ref.0
        );
        new_objects.push((annot_id, 0, object_block(annot_id, 0, annot.as_bytes())));

        add_field_to_acroform(&doc, &catalog, catalog_ref, annot_id, &mut next_id, &mut new_objects, &mut rewrites)?;
        add_widgets_to_page(&doc, page_ref, &[annot_id], &mut rewrites)?;
    }

    // ---- assemble incremental update ----
    let mut whole = bytes.clone();
    if !whole.ends_with(b"\n") {
        whole.push(b'\n');
    }

    let mut xref_entries: Vec<(u32, u16, usize)> = Vec::new();
    for (id, gen, block) in new_objects.iter().chain(rewrites.iter()) {
        let offset = whole.len();
        xref_entries.push((*id, *gen, offset));
        whole.extend_from_slice(block);
    }

    let xref_offset = whole.len();
    let new_size = next_id; // highest id + 1 (next_id already points past last)
    whole.extend_from_slice(&build_xref(&xref_entries));
    whole.extend_from_slice(
        build_trailer(new_size, catalog_ref, info_ref, prev_startxref, xref_offset).as_bytes(),
    );

    // ---- patch ByteRange + compute digest ----
    let contents_start = find_contents_start(&whole, bytes.len())
        .ok_or_else(|| cerr("CORE_CRASH", "contents placeholder not found"))?;
    // The excluded gap must cover the WHOLE Contents token including both angle
    // brackets (Adobe's convention): b1 = offset of '<', b2 = one past '>'.
    let b1 = contents_start - 1; // the '<'
    let b2 = contents_start + CONTENTS_HEX_LEN + 1; // one past the '>'
    let b3 = whole.len() - b2;
    patch_byte_range(&mut whole, bytes.len(), b1, b2, b3)
        .map_err(|e| cerr("CORE_CRASH", e))?;

    let mut hasher = Sha256::new();
    hasher.update(&whole[..b1]);
    hasher.update(&whole[b2..]);
    let doc_digest = hasher.finalize();

    let signed_attrs = cms::signed_attributes(&doc_digest, signer_der);

    // ---- persist state ----
    let handle = format!("sig-{:x}", Sha256::digest(&whole));
    let work = PathBuf::from(&req.work_dir);
    std::fs::create_dir_all(&work).ok();
    let working_pdf = work.join(format!("{handle}.pdf"));
    std::fs::write(&working_pdf, &whole)
        .map_err(|e| cerr("CORE_CRASH", format!("write working: {e}")))?;
    let out_path = work.join(format!("{handle}-signed.pdf"));

    let kind_str = match kind {
        KeyKind::Rsa => "rsa",
        KeyKind::Ecdsa => "ecdsa",
    };
    let state = State {
        working_pdf: working_pdf.to_string_lossy().into(),
        contents_start,
        signed_attrs_b64: b64().encode(&signed_attrs),
        chain_b64: req.cert_chain.clone(),
        kind: kind_str.into(),
        tsa_url: req.tsa_url.clone(),
        signer_cn: signer_cn.clone(),
        out_path: out_path.to_string_lossy().into(),
    };
    let state_path = work.join(format!("{handle}.state.json"));
    std::fs::write(&state_path, serde_json::to_vec(&state).unwrap())
        .map_err(|e| cerr("CORE_CRASH", format!("write state: {e}")))?;

    let sig_alg = match kind_str {
        "ecdsa" => "ecdsa-sha256",
        _ => "rsa-pkcs1-sha256",
    };

    Ok(PrepareResp {
        status: "need_signature".into(),
        handle,
        digest: b64().encode(&signed_attrs), // TBS bytes; shell signs with message-hash alg
        sig_alg: sig_alg.into(),
    })
}

// ---------- finalize ----------

pub fn finalize(req: FinalizeReq) -> Result<FinalizeResp, CoreErr> {
    // Locate state by handle. The work_dir is encoded in stored absolute paths.
    let state = load_state(&req.handle)?;
    let signature = b64()
        .decode(&req.signature)
        .map_err(|e| cerr("BAD_REQUEST", format!("sig b64: {e}")))?;
    let signed_attrs = b64().decode(&state.signed_attrs_b64).unwrap();
    let chain: Vec<Vec<u8>> = state
        .chain_b64
        .iter()
        .map(|s| b64().decode(s).unwrap())
        .collect();
    let kind = if state.kind == "ecdsa" {
        KeyKind::Ecdsa
    } else {
        KeyKind::Rsa
    };

    // RFC 3161 timestamp (B-T). On failure, fall back to B-B.
    let (tst, level) = match &state.tsa_url {
        Some(url) if !url.is_empty() => match tsa::fetch_token(url, &signature) {
            Ok(token) => (Some(token), "B-T"),
            Err(e) => {
                eprintln!("[pdfsigner-core] TSA failed, falling back to B-B: {e}");
                (None, "B-B")
            }
        },
        _ => (None, "B-B"),
    };

    let cms_der = cms::build_cms(&chain, &signed_attrs, &signature, &kind, tst.as_deref())
        .map_err(|e| cerr("CORE_CRASH", e))?;

    let mut hex = hex_encode(&cms_der);
    if hex.len() > CONTENTS_HEX_LEN {
        return Err(cerr("CMS_TOO_BIG", "signature exceeds reserved space"));
    }
    hex.extend(std::iter::repeat('0').take(CONTENTS_HEX_LEN - hex.len()));

    let mut whole = std::fs::read(&state.working_pdf)
        .map_err(|e| cerr("CORE_CRASH", format!("read working: {e}")))?;
    let region = &mut whole[state.contents_start..state.contents_start + CONTENTS_HEX_LEN];
    region.copy_from_slice(hex.as_bytes());

    std::fs::write(&state.out_path, &whole)
        .map_err(|e| cerr("CORE_CRASH", format!("write out: {e}")))?;

    Ok(FinalizeResp {
        status: "ok".into(),
        out: state.out_path,
        pades_level: level.into(),
        signer_cn: state.signer_cn,
    })
}

fn load_state(handle: &str) -> Result<State, CoreErr> {
    // State file path: search common temp/work dirs is brittle; the shell passes
    // the same work_dir, so the state file sits next to working pdf. We stored
    // absolute paths inside; we recover by reading from the handle-derived name
    // in the OS temp dir tree the shell uses. The shell always finalizes with the
    // working dir set, so we look relative to env PDFSIGNER_WORK if present.
    let dirs = [
        std::env::var("PDFSIGNER_WORK").ok(),
        Some(std::env::temp_dir().to_string_lossy().into()),
    ];
    for d in dirs.into_iter().flatten() {
        let p = PathBuf::from(d).join(format!("{handle}.state.json"));
        if let Ok(bytes) = std::fs::read(&p) {
            return serde_json::from_slice(&bytes)
                .map_err(|e| cerr("CORE_CRASH", format!("state parse: {e}")));
        }
    }
    Err(cerr("CORE_CRASH", "state not found for handle"))
}

// ---------- PDF helpers ----------

/// True if the document already carries a signature, detected by the presence of
/// a `/ByteRange` array. We must not rewrite the base bytes of an already-signed
/// document, as that would invalidate the existing signature's byte ranges.
fn has_existing_signature(bytes: &[u8]) -> bool {
    bytes.windows(b"/ByteRange".len()).any(|w| w == b"/ByteRange")
}

/// Round-trip the document through lopdf to emit a clean, valid cross-reference
/// table, discarding any corruption in the source xref (phantom entries, bad
/// generations, wrong offsets). Returns the normalized bytes, or `None` if the
/// rewrite fails (caller then falls back to the original bytes).
fn normalize_pdf(doc: &mut Document) -> Option<Vec<u8>> {
    let mut buf = Vec::new();
    doc.save_to(&mut buf).ok()?;
    // Sanity: a usable PDF must start with the header and end near %%EOF.
    if buf.len() < 32 || !buf.starts_with(b"%PDF-") {
        return None;
    }
    Some(buf)
}

fn object_block(id: u32, gen: u16, body: &[u8]) -> Vec<u8> {
    let mut v = format!("{id} {gen} obj\n").into_bytes();
    v.extend_from_slice(body);
    v.extend_from_slice(b"\nendobj\n");
    v
}

fn build_xref(entries: &[(u32, u16, usize)]) -> Vec<u8> {
    let mut s = String::from("xref\n");
    for (id, gen, offset) in entries {
        s.push_str(&format!("{id} 1\n{offset:010} {gen:05} n \n"));
    }
    s.into_bytes()
}

fn build_trailer(
    size: u32,
    root: (u32, u16),
    info: Option<(u32, u16)>,
    prev: i64,
    xref_offset: usize,
) -> String {
    let info_clause = match info {
        Some((id, g)) => format!(" /Info {id} {g} R"),
        None => String::new(),
    };
    format!(
        "trailer\n<< /Size {size} /Root {} {} R{info_clause} /Prev {prev} >>\nstartxref\n{xref_offset}\n%%EOF\n",
        root.0, root.1
    )
}

fn last_startxref(bytes: &[u8]) -> Option<i64> {
    let needle = b"startxref";
    let pos = bytes
        .windows(needle.len())
        .rposition(|w| w == needle)?;
    let mut i = pos + needle.len();
    while i < bytes.len() && (bytes[i] as char).is_whitespace() {
        i += 1;
    }
    let start = i;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    std::str::from_utf8(&bytes[start..i]).ok()?.parse().ok()
}

fn find_contents_start(whole: &[u8], from: usize) -> Option<usize> {
    let needle = b"/Contents <";
    let rel = whole[from..]
        .windows(needle.len())
        .position(|w| w == needle)?;
    Some(from + rel + needle.len())
}

fn patch_byte_range(
    whole: &mut [u8],
    from: usize,
    b1: usize,
    b2: usize,
    b3: usize,
) -> Result<(), String> {
    let needle = b"/ByteRange [0 ";
    let rel = whole[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .ok_or("ByteRange not found")?;
    let fs = from + rel + needle.len();
    // Fixed-width region between "[0 " and "]": three 10-digit fields + two
    // separators = 32 bytes. Write real values (NO leading zeros — Adobe rejects
    // them) and pad the region with trailing spaces so the ']' stays put.
    let region = BR_FIELD_W * 3 + 2;
    let s = format!("{b1} {b2} {b3}");
    if s.len() > region {
        return Err("ByteRange value overflow".into());
    }
    let padded = format!("{s:<region$}");
    whole[fs..fs + region].copy_from_slice(padded.as_bytes());
    Ok(())
}

/// Current UTC time as a PDF date string: D:YYYYMMDDHHmmSS+00'00'.
fn now_pdf_date() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (y, mo, d, h, mi, s) = civil_from_unix(secs);
    format!("D:{y:04}{mo:02}{d:02}{h:02}{mi:02}{s:02}+00'00'")
}

/// Convert a Unix timestamp to UTC civil time (Howard Hinnant's algorithm).
fn civil_from_unix(secs: i64) -> (i64, u32, u32, u32, u32, u32) {
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let (hh, mm, ss) = ((rem / 3600) as u32, ((rem % 3600) / 60) as u32, (rem % 60) as u32);
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = if month <= 2 { y + 1 } else { y };
    (year, month, day, hh, mm, ss)
}

fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn compose_lines(p: &Placement, req: &PrepareReq, signer_cn: &str) -> Vec<String> {
    if !p.lines.is_empty() {
        return p.lines.clone();
    }
    let mut lines = vec![format!("Firmado por: {}", req.name.clone().unwrap_or_else(|| signer_cn.to_string()))];
    if let Some(r) = &req.reason {
        lines.push(format!("Motivo: {r}"));
    }
    if let Some(l) = &req.location {
        lines.push(format!("Lugar: {l}"));
    }
    lines
}

/// Build the appearance Form XObject for one placement (image or text),
/// pushing the needed objects and returning the ` /AP << /N id 0 R >>` clause.
fn build_appearance(
    p: &Placement,
    req: &PrepareReq,
    signer_cn: &str,
    next_id: &mut u32,
    new_objects: &mut Vec<(u32, u16, Vec<u8>)>,
) -> Result<String, CoreErr> {
    if let Some(img) = &p.image {
        // STEP 5 — Image appearance built with Adobe's layered signature
        // appearance model (n0 blank background, n2 content, FRM wrapper, N
        // top), which is exactly how BOTH Acrobat and AutoFirma structure an
        // image signature appearance. A single flat image form (Step 4) is
        // rejected by Acrobat; the layered model validates.
        // Image is OPAQUE RGB (no /SMask) — composited over white.
        let rgba = std::fs::read(&img.rgba_path)
            .map_err(|e| cerr("BAD_REQUEST", format!("read appearance image: {e}")))?;
        let expected = (img.width as usize) * (img.height as usize) * 4;
        if rgba.len() != expected {
            return Err(cerr("BAD_REQUEST", format!(
                "appearance image size mismatch: {} != {expected}", rgba.len())));
        }
        let rgb = composite_over_white(&rgba);
        let rgb_z = deflate(&rgb);

        let image_id = *next_id; *next_id += 1;
        let n0_id = *next_id; *next_id += 1;
        let n2_id = *next_id; *next_id += 1;
        let frm_id = *next_id; *next_id += 1;
        let ap_id = *next_id; *next_id += 1;

        // Im0: opaque image, no SMask.
        let image = image_stream(img.width, img.height, "DeviceRGB", None, &rgb_z);
        new_objects.push((image_id, 0, object_block(image_id, 0, &image)));

        // n0: blank background layer (matches both references' "% DSBlank").
        let n0 = layer_form(100.0, 100.0, &[], false, "% DSBlank\n");
        new_objects.push((n0_id, 0, object_block(n0_id, 0, &n0)));

        // n2: content layer — draws the image scaled to the box.
        let n2_content = format!("q {w:.3} 0 0 {h:.3} 0 0 cm /Im0 Do Q", w = p.w, h = p.h);
        let n2 = layer_form(p.w, p.h, &[("Im0", image_id)], false, &n2_content);
        new_objects.push((n2_id, 0, object_block(n2_id, 0, &n2)));

        // FRM: composes n0 over n2.
        let frm_content = "q 1 0 0 1 0 0 cm /n0 Do Q\nq 1 0 0 1 0 0 cm /n2 Do Q";
        let frm = layer_form(p.w, p.h, &[("n0", n0_id), ("n2", n2_id)], false, frm_content);
        new_objects.push((frm_id, 0, object_block(frm_id, 0, &frm)));

        // N: top appearance referenced by the widget's /AP /N — draws FRM.
        let n_form = layer_form(p.w, p.h, &[("FRM", frm_id)], false, "q 1 0 0 1 0 0 cm /FRM Do Q");
        new_objects.push((ap_id, 0, object_block(ap_id, 0, &n_form)));

        Ok(format!(" /AP << /N {ap_id} 0 R >>"))
    } else {
        // OPTION B — Hybrid appearance in the Adobe layered model: n2 draws
        // CRISP VECTOR TEXT plus zero or more OPAQUE images (logo/handwriting,
        // QR), exactly how Acrobat and AutoFirma compose their n2 layer
        // (image `Do` + BT/Tj text). No /SMask, no transparency group.
        let lines = compose_lines(p, req, signer_cn);

        // Build an opaque image XObject for each placed image; collect its
        // resource name + the n2 draw op (scaled to its sub-rect).
        let mut img_refs: Vec<(String, u32)> = Vec::new();
        let mut draw_ops = String::new();
        for (i, pim) in p.images.iter().enumerate() {
            let rgba = std::fs::read(&pim.rgba_path)
                .map_err(|e| cerr("BAD_REQUEST", format!("read placed image: {e}")))?;
            let expected = (pim.width as usize) * (pim.height as usize) * 4;
            if rgba.len() != expected {
                return Err(cerr("BAD_REQUEST", format!(
                    "placed image size mismatch: {} != {expected}", rgba.len())));
            }
            let rgb = composite_over_white(&rgba);
            let rgb_z = deflate(&rgb);
            let img_id = *next_id; *next_id += 1;
            let image = image_stream(pim.width, pim.height, "DeviceRGB", None, &rgb_z);
            new_objects.push((img_id, 0, object_block(img_id, 0, &image)));
            let name = format!("Im{i}");
            draw_ops.push_str(&format!(
                "q {w:.3} 0 0 {h:.3} {x:.3} {y:.3} cm /{name} Do Q\n",
                w = pim.w, h = pim.h, x = pim.x, y = pim.y
            ));
            img_refs.push((name, img_id));
        }

        let n0_id = *next_id; *next_id += 1;
        let n2_id = *next_id; *next_id += 1;
        let frm_id = *next_id; *next_id += 1;
        let ap_id = *next_id; *next_id += 1;

        // n0: blank background layer.
        let n0 = layer_form(100.0, 100.0, &[], false, "% DSBlank\n");
        new_objects.push((n0_id, 0, object_block(n0_id, 0, &n0)));

        // n2: background fill (behind), opaque images, then vector text, then
        // border (on top) — all vector except the placed images.
        let mut n2_content = String::new();
        if p.background {
            // Opaque white fill of the whole box.
            n2_content.push_str(&format!("q 1 1 1 rg 0 0 {w:.3} {h:.3} re f Q\n", w = p.w, h = p.h));
        }
        n2_content.push_str(&draw_ops);
        let size = if p.font_size > 0.0 { p.font_size } else { 9.0 };
        let right_pad = 2.0;
        let avail = if p.text_w > 0.0 {
            p.text_w
        } else {
            (p.w - p.text_x - right_pad).max(0.0)
        };
        n2_content.push_str(&text_content(avail, p.h, p.text_x, size, &lines));
        if p.border {
            // Thin gray stroke just inside the box edge.
            n2_content.push_str(&format!(
                "q 0.5 0.5 0.5 RG 1 w 0.5 0.5 {w:.3} {h:.3} re S Q\n",
                w = p.w - 1.0, h = p.h - 1.0
            ));
        }
        let img_ref_slice: Vec<(&str, u32)> =
            img_refs.iter().map(|(n, id)| (n.as_str(), *id)).collect();
        let n2 = layer_form(p.w, p.h, &img_ref_slice, true, &n2_content);
        new_objects.push((n2_id, 0, object_block(n2_id, 0, &n2)));

        // FRM: composes n0 over n2.
        let frm_content = "q 1 0 0 1 0 0 cm /n0 Do Q\nq 1 0 0 1 0 0 cm /n2 Do Q";
        let frm = layer_form(p.w, p.h, &[("n0", n0_id), ("n2", n2_id)], false, frm_content);
        new_objects.push((frm_id, 0, object_block(frm_id, 0, &frm)));

        // N: top appearance referenced by the widget's /AP /N.
        let n_form = layer_form(p.w, p.h, &[("FRM", frm_id)], false, "q 1 0 0 1 0 0 cm /FRM Do Q");
        new_objects.push((ap_id, 0, object_block(ap_id, 0, &n_form)));

        Ok(format!(" /AP << /N {ap_id} 0 R >>"))
    }
}

/// Merge a signature field reference into the catalog's AcroForm (creating one
/// if absent) and set SigFlags. Rewrites the AcroForm or catalog object.
fn add_field_to_acroform(
    doc: &Document,
    catalog: &lopdf::Dictionary,
    catalog_ref: (u32, u16),
    field_id: u32,
    next_id: &mut u32,
    new_objects: &mut Vec<(u32, u16, Vec<u8>)>,
    rewrites: &mut Vec<(u32, u16, Vec<u8>)>,
) -> Result<(), CoreErr> {
    match catalog.get(b"AcroForm") {
        Ok(Object::Reference(af_ref)) => {
            let af = doc.get_object(*af_ref).and_then(|o| o.as_dict())
                .map_err(|e| cerr("BAD_PDF", format!("acroform: {e}")))?.clone();
            let af_bytes = acroform_with_field(&af, field_id);
            rewrites.push((af_ref.0, af_ref.1, object_block(af_ref.0, af_ref.1, &af_bytes)));
        }
        Ok(Object::Dictionary(af)) => {
            let af_bytes = acroform_with_field(af, field_id);
            let mut cat2 = catalog.clone();
            cat2.set("AcroForm", parse_back(&af_bytes));
            let cat_bytes = serialize_dict(&cat2);
            rewrites.push((catalog_ref.0, catalog_ref.1, object_block(catalog_ref.0, catalog_ref.1, &cat_bytes)));
        }
        _ => {
            let acro_id = *next_id; *next_id += 1;
            // /DA references the /Helv font, so /DR must define it. Without /DR,
            // Acrobat's appearance regeneration during validation can fail with
            // "An error occurred while attempting to validate this signature".
            let af_bytes = format!(
                "<< /Fields [{field_id} 0 R] /SigFlags 3 /DA (/Helv 0 Tf 0 g) \
/DR << /Font << /Helv << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> >> >>"
            );
            new_objects.push((acro_id, 0, object_block(acro_id, 0, af_bytes.as_bytes())));
            let mut cat2 = catalog.clone();
            cat2.set("AcroForm", Object::Reference((acro_id, 0)));
            let cat_bytes = serialize_dict(&cat2);
            rewrites.push((catalog_ref.0, catalog_ref.1, object_block(catalog_ref.0, catalog_ref.1, &cat_bytes)));
        }
    }
    Ok(())
}

/// Append widget annotation references to a page's /Annots array.
fn add_widgets_to_page(
    doc: &Document,
    page_ref: (u32, u16),
    ids: &[u32],
    rewrites: &mut Vec<(u32, u16, Vec<u8>)>,
) -> Result<(), CoreErr> {
    let page = doc.get_object(page_ref).and_then(|o| o.as_dict())
        .map_err(|e| cerr("BAD_PDF", format!("page: {e}")))?.clone();
    match page.get(b"Annots") {
        Ok(Object::Reference(arr_ref)) => {
            let arr = doc.get_object(*arr_ref).and_then(|o| o.as_array())
                .map_err(|e| cerr("BAD_PDF", format!("annots: {e}")))?.clone();
            let arr_bytes = array_with_refs(&arr, ids);
            rewrites.push((arr_ref.0, arr_ref.1, object_block(arr_ref.0, arr_ref.1, &arr_bytes)));
        }
        Ok(Object::Array(arr)) => {
            let arr_bytes = array_with_refs(arr, ids);
            let mut page2 = page.clone();
            page2.set("Annots", parse_back(&arr_bytes));
            let page_bytes = serialize_dict(&page2);
            rewrites.push((page_ref.0, page_ref.1, object_block(page_ref.0, page_ref.1, &page_bytes)));
        }
        _ => {
            let mut page2 = page.clone();
            page2.set("Annots", Object::Array(ids.iter().map(|i| Object::Reference((*i, 0))).collect()));
            let page_bytes = serialize_dict(&page2);
            rewrites.push((page_ref.0, page_ref.1, object_block(page_ref.0, page_ref.1, &page_bytes)));
        }
    }
    Ok(())
}

/// Composite straight-alpha RGBA8 over a white background, returning opaque
/// RGB8. Matches how Acrobat / AutoFirma embed a (possibly transparent)
/// signature image: flattened onto white, no soft mask.
fn composite_over_white(rgba: &[u8]) -> Vec<u8> {
    let px = rgba.len() / 4;
    let mut rgb = Vec::with_capacity(px * 3);
    for chunk in rgba.chunks_exact(4) {
        let a = chunk[3] as u32;
        // out = src*a + white*(255-a), rounded, all in 0..=255.
        for &c in &chunk[0..3] {
            let v = (c as u32 * a + 255 * (255 - a) + 127) / 255;
            rgb.push(v as u8);
        }
    }
    rgb
}

/// zlib-compress (PDF /FlateDecode).
fn deflate(data: &[u8]) -> Vec<u8> {
    use flate2::write::ZlibEncoder;
    use flate2::Compression;
    use std::io::Write;
    let mut e = ZlibEncoder::new(Vec::new(), Compression::default());
    e.write_all(data).unwrap();
    e.finish().unwrap()
}

/// An image XObject body (`obj`/`endobj` added by caller). `data` is the
/// already-deflated sample stream.
fn image_stream(w: u32, h: u32, cs: &str, smask: Option<u32>, data: &[u8]) -> Vec<u8> {
    let smask_clause = match smask {
        Some(id) => format!(" /SMask {id} 0 R"),
        None => String::new(),
    };
    let header = format!(
        "<< /Type /XObject /Subtype /Image /Width {w} /Height {h} \
/ColorSpace /{cs} /BitsPerComponent 8 /Filter /FlateDecode{smask_clause} /Length {} >>\nstream\n",
        data.len()
    );
    let mut out = header.into_bytes();
    out.extend_from_slice(data);
    out.extend_from_slice(b"\nendstream");
    out
}

/// A layer Form XObject for the Adobe n0/n2/FRM/N signature appearance model.
///
/// `xobjects` are `(name, id)` pairs placed in `/Resources /XObject` (e.g.
/// `("Im0", image_id)` or `("FRM", frm_id)`). When `with_font` is true the
/// `/Helv` Helvetica Type1 font is declared in `/Resources /Font` so the layer
/// can draw vector text. `/Matrix` and `/ProcSet` are spec-optional, but
/// Acrobat regenerates a signature widget's appearance during validation and a
/// form that omits them can make that rebuild fail. Both Acrobat's and
/// AutoFirma's Acrobat-accepted image signatures use exactly this layered
/// structure, so we match it byte-for-byte.
fn layer_form(w: f64, h: f64, xobjects: &[(&str, u32)], with_font: bool, content: &str) -> Vec<u8> {
    let xobj_clause = if xobjects.is_empty() {
        String::new()
    } else {
        let refs: String = xobjects
            .iter()
            .map(|(name, id)| format!("/{name} {id} 0 R "))
            .collect();
        format!("/XObject << {refs}>> ")
    };
    let font_clause = if with_font {
        "/Font << /Helv << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> "
    } else {
        ""
    };
    let header = format!(
        "<< /Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 {w} {h}] \
/Matrix [1 0 0 1 0 0] \
/Resources << /ProcSet [/PDF /Text /ImageB /ImageC /ImageI] {xobj_clause}{font_clause}>> \
/Length {} >>\nstream\n",
        content.len()
    );
    let mut out = header.into_bytes();
    out.extend_from_slice(content.as_bytes());
    out.extend_from_slice(b"\nendstream");
    out
}

/// Build the content stream that draws `lines` as vector text, top-down, from
/// the top of an `h`-tall box. Used by the n2 layer of the layered appearance.
/// Lines are truncated with an ellipsis to fit `avail` points wide, so text
/// drawn in the signed appearance never overflows/clips the box. `size` is the
/// font size in points.
fn text_content(avail: f64, h: f64, text_x: f64, size: f64, lines: &[String]) -> String {
    let leading = size + 2.0;
    // Vertically center the text block (same formula as the preview renderer):
    // first baseline at (h + total)/2 - leading, then T* steps down by leading.
    let total = leading * lines.len() as f64;
    let top_y = (h + total) / 2.0 - leading;
    let mut content = String::from("q BT /Helv ");
    content.push_str(&format!("{size} Tf {leading} TL 0 g {text_x:.1} "));
    content.push_str(&format!("{top_y:.1} Td\n"));
    for (i, line) in lines.iter().enumerate() {
        if i > 0 {
            content.push_str("T* ");
        }
        let fitted = truncate_to_width(line, size, avail);
        content.push('(');
        content.push_str(&escape_pdf_text(&fitted));
        content.push_str(") Tj\n");
    }
    content.push_str("ET Q");
    content
}

/// Escape a string for a PDF literal `( … )` string, encoded as WinAnsi
/// (CP1252) single bytes. The n2 font is declared with /WinAnsiEncoding, so
/// accented characters (á é í ó ú ñ ü ¿ ¡ …) must be emitted as their WinAnsi
/// byte, not UTF-8. High bytes are written as `\ddd` octal escapes so the
/// returned String stays valid ASCII. Characters not representable in WinAnsi
/// become '?'.
fn escape_pdf_text(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '(' | ')' | '\\' => {
                out.push('\\');
                out.push(c);
            }
            _ => match winansi_byte(c) {
                Some(b) if b < 0x80 => out.push(b as char),
                Some(b) => out.push_str(&format!("\\{b:03o}")),
                None => out.push('?'),
            },
        }
    }
    out
}

/// Map a Unicode scalar to its WinAnsiEncoding (CP1252) byte, or None if it is
/// not representable. ASCII and Latin-1 map 1:1; the 0x80–0x9F range holds the
/// CP1252 typographic specials.
fn winansi_byte(c: char) -> Option<u8> {
    let cp = c as u32;
    match cp {
        0x20..=0x7E | 0xA0..=0xFF => Some(cp as u8),
        0x20AC => Some(0x80), // €
        0x201A => Some(0x82),
        0x0192 => Some(0x83),
        0x201E => Some(0x84),
        0x2026 => Some(0x85), // …
        0x2020 => Some(0x86),
        0x2021 => Some(0x87),
        0x02C6 => Some(0x88),
        0x2030 => Some(0x89),
        0x0160 => Some(0x8A),
        0x2039 => Some(0x8B),
        0x0152 => Some(0x8C), // Œ
        0x017D => Some(0x8E),
        0x2018 => Some(0x91), // ‘
        0x2019 => Some(0x92), // ’
        0x201C => Some(0x93), // “
        0x201D => Some(0x94), // ”
        0x2022 => Some(0x95), // •
        0x2013 => Some(0x96), // –
        0x2014 => Some(0x97), // —
        0x02DC => Some(0x98),
        0x2122 => Some(0x99), // ™
        0x0161 => Some(0x9A),
        0x203A => Some(0x9B),
        0x0153 => Some(0x9C), // œ
        0x017E => Some(0x9E),
        0x0178 => Some(0x9F), // Ÿ
        _ => None,
    }
}

/// Helvetica glyph advance width in 1/1000 em (Standard 14 AFM metrics).
/// Accented Latin-1 letters share their base letter's advance in Helvetica, so
/// they are folded first. Used to measure/truncate text to fit the box.
fn helv_width(c: char) -> u32 {
    let c = match c {
        'á' | 'à' | 'â' | 'ä' | 'ã' | 'å' | 'ª' => 'a',
        'é' | 'è' | 'ê' | 'ë' => 'e',
        'í' | 'ì' | 'î' | 'ï' => 'i',
        'ó' | 'ò' | 'ô' | 'ö' | 'õ' | 'º' => 'o',
        'ú' | 'ù' | 'û' | 'ü' => 'u',
        'ñ' => 'n',
        'ç' => 'c',
        'Á' | 'À' | 'Â' | 'Ä' | 'Ã' | 'Å' => 'A',
        'É' | 'È' | 'Ê' | 'Ë' => 'E',
        'Í' | 'Ì' | 'Î' | 'Ï' => 'I',
        'Ó' | 'Ò' | 'Ô' | 'Ö' | 'Õ' => 'O',
        'Ú' | 'Ù' | 'Û' | 'Ü' => 'U',
        'Ñ' => 'N',
        'Ç' => 'C',
        '¿' => '?',
        '¡' => '!',
        other => other,
    };
    match c {
        ' ' => 278, '!' => 278, '"' => 355, '#' => 556, '$' => 556, '%' => 889,
        '&' => 667, '\'' => 191, '(' => 333, ')' => 333, '*' => 389, '+' => 584,
        ',' => 278, '-' => 333, '.' => 278, '/' => 278,
        '0'..='9' => 556, ':' => 278, ';' => 278, '<' => 584, '=' => 584,
        '>' => 584, '?' => 556, '@' => 1015,
        'A' => 667, 'B' => 667, 'C' => 722, 'D' => 722, 'E' => 667, 'F' => 611,
        'G' => 778, 'H' => 722, 'I' => 278, 'J' => 500, 'K' => 667, 'L' => 556,
        'M' => 833, 'N' => 722, 'O' => 778, 'P' => 667, 'Q' => 778, 'R' => 722,
        'S' => 667, 'T' => 611, 'U' => 722, 'V' => 667, 'W' => 944, 'X' => 667,
        'Y' => 667, 'Z' => 611, '[' => 278, '\\' => 278, ']' => 278, '^' => 469,
        '_' => 556, '`' => 333,
        'a' => 556, 'b' => 556, 'c' => 500, 'd' => 556, 'e' => 556, 'f' => 278,
        'g' => 556, 'h' => 556, 'i' => 222, 'j' => 222, 'k' => 500, 'l' => 222,
        'm' => 833, 'n' => 556, 'o' => 556, 'p' => 556, 'q' => 556, 'r' => 333,
        's' => 500, 't' => 278, 'u' => 556, 'v' => 500, 'w' => 722, 'x' => 500,
        'y' => 500, 'z' => 500, '{' => 334, '|' => 260, '}' => 334, '~' => 584,
        '…' => 1000,
        _ => 556,
    }
}

/// Width of `s` at `size` points, in points.
fn text_width(s: &str, size: f64) -> f64 {
    s.chars().map(|c| helv_width(c) as f64).sum::<f64>() * size / 1000.0
}

/// Truncate `line` to `max` points, appending '…' if it didn't fit (mirrors the
/// preview's `.byTruncatingTail`, so output text doesn't get clipped by the box).
fn truncate_to_width(line: &str, size: f64, max: f64) -> String {
    if max <= 0.0 || text_width(line, size) <= max {
        return line.to_string();
    }
    let ell_w = helv_width('…') as f64 * size / 1000.0;
    let budget = max - ell_w;
    if budget <= 0.0 {
        return "…".to_string();
    }
    let mut acc = 0.0;
    let mut out = String::new();
    for c in line.chars() {
        let w = helv_width(c) as f64 * size / 1000.0;
        if acc + w > budget {
            break;
        }
        acc += w;
        out.push(c);
    }
    out.push('…');
    out
}

fn acroform_with_field(af: &lopdf::Dictionary, annot_id: u32) -> Vec<u8> {
    let mut af2 = af.clone();
    // Append to Fields.
    let mut fields = match af.get(b"Fields") {
        Ok(Object::Array(a)) => a.clone(),
        _ => Vec::new(),
    };
    fields.push(Object::Reference((annot_id, 0)));
    af2.set("Fields", Object::Array(fields));
    // SigFlags |= 3 (SignaturesExist | AppendOnly).
    af2.set("SigFlags", Object::Integer(3));
    serialize_dict(&af2)
}

fn array_with_refs(arr: &[Object], ids: &[u32]) -> Vec<u8> {
    let mut a = arr.to_vec();
    for id in ids {
        a.push(Object::Reference((*id, 0)));
    }
    serialize_array(&a)
}

// ---------- lopdf Object -> PDF bytes ----------

fn serialize_dict(d: &lopdf::Dictionary) -> Vec<u8> {
    let mut out = Vec::new();
    serialize_object(&Object::Dictionary(d.clone()), &mut out);
    out
}

fn serialize_array(a: &[Object]) -> Vec<u8> {
    let mut out = Vec::new();
    serialize_object(&Object::Array(a.to_vec()), &mut out);
    out
}

fn serialize_object(obj: &Object, out: &mut Vec<u8>) {
    match obj {
        Object::Null => out.extend_from_slice(b"null"),
        Object::Boolean(b) => out.extend_from_slice(if *b { b"true" } else { b"false" }),
        Object::Integer(i) => out.extend_from_slice(i.to_string().as_bytes()),
        Object::Real(r) => out.extend_from_slice(format!("{r}").as_bytes()),
        Object::Name(n) => {
            out.push(b'/');
            for &b in n {
                if b.is_ascii_alphanumeric() || b"-_.+".contains(&b) {
                    out.push(b);
                } else {
                    out.extend_from_slice(format!("#{b:02X}").as_bytes());
                }
            }
        }
        Object::String(s, fmt) => match fmt {
            lopdf::StringFormat::Literal => {
                out.push(b'(');
                for &b in s {
                    if b == b'(' || b == b')' || b == b'\\' {
                        out.push(b'\\');
                    }
                    out.push(b);
                }
                out.push(b')');
            }
            lopdf::StringFormat::Hexadecimal => {
                out.push(b'<');
                for &b in s {
                    out.extend_from_slice(format!("{b:02X}").as_bytes());
                }
                out.push(b'>');
            }
        },
        Object::Reference((id, gen)) => {
            out.extend_from_slice(format!("{id} {gen} R").as_bytes())
        }
        Object::Array(a) => {
            out.push(b'[');
            for (i, item) in a.iter().enumerate() {
                if i > 0 {
                    out.push(b' ');
                }
                serialize_object(item, out);
            }
            out.push(b']');
        }
        Object::Dictionary(d) => {
            out.extend_from_slice(b"<< ");
            for (k, v) in d.iter() {
                out.push(b'/');
                out.extend_from_slice(k);
                out.push(b' ');
                serialize_object(v, out);
                out.push(b' ');
            }
            out.extend_from_slice(b">>");
        }
        Object::Stream(_) => out.extend_from_slice(b"null"), // not expected for our targets
    }
}

/// Re-parse serialized dict/array bytes back into a lopdf Object for embedding.
/// We only ever round-trip our own freshly serialized fragments here.
fn parse_back(bytes: &[u8]) -> Object {
    // Wrap as a tiny indirect object and let lopdf parse it.
    let doc = format!(
        "%PDF-1.7\n1 0 obj\n{}\nendobj\ntrailer\n<< /Root 1 0 R >>\n",
        String::from_utf8_lossy(bytes)
    );
    if let Ok(d) = Document::load_mem(doc.as_bytes()) {
        if let Ok(o) = d.get_object((1, 0)) {
            return o.clone();
        }
    }
    Object::Null
}
