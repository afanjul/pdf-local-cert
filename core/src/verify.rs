//! PAdES verification: recompute the byte-range digest, parse the embedded CMS,
//! confirm the signed messageDigest matches, and (for RSA) verify the signature
//! over the SignedAttributes. Reports signer identity, timestamp presence, level.

use crate::cms::{cn_of, read_tlv_header};
use crate::protocol::*;
use crate::{cerr, CoreErr};
use sha2::{Digest, Sha256};
use x509_cert::Certificate;
use der::{Decode, Encode};

const OID_ATTR_MESSAGE_DIGEST: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04];
const OID_TIMESTAMP_TOKEN: &[u8] =
    &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x02, 0x0e];

pub fn verify(req: VerifyReq) -> Result<VerifyResp, CoreErr> {
    let bytes = std::fs::read(&req.pdf).map_err(|e| cerr("BAD_PDF", format!("read: {e}")))?;
    let mut sigs = Vec::new();

    for (br, contents) in find_signatures(&bytes) {
        sigs.push(verify_one(&bytes, &br, &contents));
    }

    if sigs.is_empty() {
        return Err(cerr("NO_SIGNATURE", "no signature found in PDF"));
    }
    Ok(VerifyResp {
        status: "ok".into(),
        signatures: sigs,
    })
}

fn verify_one(bytes: &[u8], br: &[usize; 4], cms_der: &[u8]) -> SigInfo {
    // Recompute document digest over the ByteRange.
    let mut h = Sha256::new();
    h.update(&bytes[br[0]..br[0] + br[1]]);
    h.update(&bytes[br[2]..br[2] + br[3]]);
    let doc_digest = h.finalize().to_vec();

    let covers_whole = br[2] + br[3] >= last_eof(bytes);

    // PAdES requires the excluded gap to be exactly the /Contents token including
    // both angle brackets: byte at br[1] must be '<' and byte before br[2] must be
    // '>'. Signatures that leave the brackets inside the signed range (a common
    // bug) are what Adobe rejects as "/Contents illegal data".
    let boundary_ok =
        bytes.get(br[1]) == Some(&b'<') && br[2] >= 1 && bytes.get(br[2] - 1) == Some(&b'>');

    let parsed = parse_cms(cms_der);
    let (signer_cn, issuer_cn) = match &parsed.signer_cert {
        Some(der) => match Certificate::from_der(der) {
            Ok(c) => (
                cn_of(&c.tbs_certificate.subject.to_der().unwrap_or_default()),
                cn_of(&c.tbs_certificate.issuer.to_der().unwrap_or_default()),
            ),
            Err(_) => ("(unparseable)".into(), "(unparseable)".into()),
        },
        None => ("(none)".into(), "(none)".into()),
    };

    let digest_ok = parsed
        .message_digest
        .as_ref()
        .map(|md| md == &doc_digest)
        .unwrap_or(false);

    // Cryptographic check (RSA over the SignedAttributes).
    let crypto_ok = rsa_verify(&parsed);

    let has_ts = parsed.has_timestamp;
    let level = if has_ts { "B-T" } else { "B-B" };

    let valid = digest_ok && covers_whole && boundary_ok && crypto_ok != Some(false);
    let detail = format!(
        "digest_match={digest_ok} crypto={} covers_whole={covers_whole} contents_boundary={boundary_ok}",
        match crypto_ok {
            Some(true) => "ok",
            Some(false) => "FAIL",
            None => "structural-only",
        }
    );

    SigInfo {
        valid,
        signer_cn,
        issuer_cn,
        signing_time: None,
        has_timestamp: has_ts,
        pades_level: level.into(),
        byte_range_covers_whole_file: covers_whole,
        detail,
    }
}

struct ParsedCms {
    signer_cert: Option<Vec<u8>>,
    message_digest: Option<Vec<u8>>,
    signed_attrs_retagged: Option<Vec<u8>>, // SET (0x31) form, the signed bytes
    signature: Option<Vec<u8>>,
    has_timestamp: bool,
    /// SignerInfo's issuerAndSerialNumber, used to pick the real signer cert
    /// out of a set that may also contain CA, TSA and OCSP responder certs.
    sid_issuer: Option<Vec<u8>>, // issuer Name DER (full TLV)
    sid_serial: Option<Vec<u8>>, // serialNumber INTEGER DER (full TLV)
}

/// Split a SEQUENCE/SET content into its child TLVs as (tag, full_bytes).
fn children(content: &[u8]) -> Vec<(u8, Vec<u8>)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < content.len() {
        if let Some((tag, len, hdr)) = read_tlv_header(&content[i..]) {
            let end = i + hdr + len;
            if end > content.len() {
                break;
            }
            out.push((tag, content[i..end].to_vec()));
            i = end;
        } else {
            break;
        }
    }
    out
}

fn body(tlv: &[u8]) -> &[u8] {
    if let Some((_, len, hdr)) = read_tlv_header(tlv) {
        &tlv[hdr..hdr + len]
    } else {
        &[]
    }
}

fn parse_cms(der: &[u8]) -> ParsedCms {
    let mut p = ParsedCms {
        signer_cert: None,
        message_digest: None,
        signed_attrs_retagged: None,
        signature: None,
        has_timestamp: false,
        sid_issuer: None,
        sid_serial: None,
    };

    // ContentInfo SEQ { OID, [0] SignedData }
    let ci = children(body(der));
    let signed_data_ctx = ci.iter().find(|(t, _)| *t == 0xA0);
    let Some((_, sd_ctx)) = signed_data_ctx else { return p };
    let sd = children(body(sd_ctx)); // SignedData SEQ children
    let sd_children = if sd.len() == 1 && sd[0].0 == 0x30 {
        children(body(&sd[0].1))
    } else {
        sd
    };

    // Collect every certificate from the [0] IMPLICIT CertificateSet.
    let mut all_certs: Vec<Vec<u8>> = Vec::new();
    if let Some((_, certs)) = sd_children.iter().find(|(t, _)| *t == 0xA0) {
        for (t, c) in children(body(certs)) {
            if t == 0x30 {
                all_certs.push(c);
            }
        }
    }

    // signerInfos = last SET (0x31)
    if let Some((_, sis)) = sd_children.iter().rev().find(|(t, _)| *t == 0x31) {
        if let Some((_, si)) = children(body(sis)).into_iter().find(|(t, _)| *t == 0x30) {
            parse_signer_info(body(&si), &mut p);
        }
    }

    // Pick the cert matching the SignerInfo issuer+serial; fall back to first.
    p.signer_cert = select_signer_cert(&all_certs, &p).or_else(|| all_certs.first().cloned());
    p
}

/// Match the SignerInfo's issuerAndSerialNumber against the cert set.
fn select_signer_cert(certs: &[Vec<u8>], p: &ParsedCms) -> Option<Vec<u8>> {
    let want_issuer = p.sid_issuer.as_ref()?;
    let want_serial = p.sid_serial.as_ref()?;
    for der in certs {
        let cert = match Certificate::from_der(der) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let issuer = cert.tbs_certificate.issuer.to_der().unwrap_or_default();
        let serial = cert.tbs_certificate.serial_number.to_der().unwrap_or_default();
        if &issuer == want_issuer && &serial == want_serial {
            return Some(der.clone());
        }
    }
    None
}

fn parse_signer_info(si_body: &[u8], p: &mut ParsedCms) {
    let parts = children(si_body);
    // sid = issuerAndSerialNumber: first SEQUENCE (0x30) child (after version 0x02,
    // before digestAlgorithm). Its children are issuer Name (SEQ) and serial (INT).
    if let Some((_, sid)) = parts.iter().find(|(t, _)| *t == 0x30) {
        let sid_parts = children(body(sid));
        if let Some((_, issuer)) = sid_parts.iter().find(|(t, _)| *t == 0x30) {
            p.sid_issuer = Some(issuer.clone());
        }
        if let Some((_, serial)) = sid_parts.iter().find(|(t, _)| *t == 0x02) {
            p.sid_serial = Some(serial.clone());
        }
    }
    // signedAttrs [0] IMPLICIT (0xA0)
    if let Some((_, attrs)) = parts.iter().find(|(t, _)| *t == 0xA0) {
        let mut retag = attrs.clone();
        retag[0] = 0x31;
        p.signed_attrs_retagged = Some(retag);
        // messageDigest within attrs
        p.message_digest = find_attr_octet(body(attrs), OID_ATTR_MESSAGE_DIGEST);
    }
    // signature = OCTET STRING (0x04)
    if let Some((_, sig)) = parts.iter().find(|(t, _)| *t == 0x04) {
        p.signature = Some(body(sig).to_vec());
    }
    // unsignedAttrs [1] (0xA1) -> timestamp token?
    if let Some((_, un)) = parts.iter().find(|(t, _)| *t == 0xA1) {
        p.has_timestamp = contains_oid(un, OID_TIMESTAMP_TOKEN);
    }
}

/// Find attribute SEQ { OID == target, SET { OCTET } } and return the octet bytes.
fn find_attr_octet(attrs_body: &[u8], target_oid: &[u8]) -> Option<Vec<u8>> {
    for (t, attr) in children(attrs_body) {
        if t != 0x30 {
            continue;
        }
        let kids = children(body(&attr));
        if kids.len() >= 2 && kids[0].0 == 0x06 && body(&kids[0].1) == target_oid {
            // kids[1] = SET; first child OCTET
            if let Some((_, oct)) = children(body(&kids[1].1)).into_iter().find(|(t, _)| *t == 0x04) {
                return Some(body(&oct).to_vec());
            }
        }
    }
    None
}

fn contains_oid(haystack: &[u8], oid: &[u8]) -> bool {
    if oid.len() + 2 > haystack.len() {
        return false;
    }
    haystack.windows(oid.len()).any(|w| w == oid)
}

fn rsa_verify(p: &ParsedCms) -> Option<bool> {
    use rsa::pkcs1::DecodeRsaPublicKey;
    use rsa::pkcs1v15::{Signature, VerifyingKey};
    use rsa::signature::Verifier;

    let cert_der = p.signer_cert.as_ref()?;
    let signed = p.signed_attrs_retagged.as_ref()?;
    let sig_bytes = p.signature.as_ref()?;

    let cert = Certificate::from_der(cert_der).ok()?;
    let spki = cert.tbs_certificate.subject_public_key_info;
    // RSA only here; ECDSA -> structural-only (None).
    let pub_der = spki.subject_public_key.as_bytes()?;
    let pubkey = rsa::RsaPublicKey::from_pkcs1_der(pub_der).ok()?;
    let vk = VerifyingKey::<Sha256>::new(pubkey);
    let sig = Signature::try_from(sig_bytes.as_slice()).ok()?;
    Some(vk.verify(signed, &sig).is_ok())
}

// ---------- locate signatures in raw PDF ----------

fn find_signatures(bytes: &[u8]) -> Vec<([usize; 4], Vec<u8>)> {
    let mut out = Vec::new();
    let needle = b"/ByteRange";
    let mut i = 0;
    while let Some(rel) = bytes[i..].windows(needle.len()).position(|w| w == needle) {
        let pos = i + rel;
        i = pos + needle.len();
        if let Some(br) = parse_byte_range(&bytes[pos..]) {
            // The excluded gap [br[1]..br[2]] is exactly the Contents hex digits
            // (first hex digit through the byte before '>'), no surrounding brackets.
            if br[2] <= bytes.len() && br[1] <= br[2] {
                let gap = &bytes[br[1]..br[2]];
                if let Some(cms) = decode_hex(gap) {
                    out.push((br, cms));
                }
            }
        }
    }
    out
}

fn parse_byte_range(buf: &[u8]) -> Option<[usize; 4]> {
    let lb = buf.iter().position(|&b| b == b'[')?;
    let rb = buf[lb..].iter().position(|&b| b == b']')? + lb;
    let inner = std::str::from_utf8(&buf[lb + 1..rb]).ok()?;
    let nums: Vec<usize> = inner
        .split_whitespace()
        .filter_map(|s| s.parse().ok())
        .collect();
    if nums.len() == 4 {
        Some([nums[0], nums[1], nums[2], nums[3]])
    } else {
        None
    }
}

fn decode_hex(hex: &[u8]) -> Option<Vec<u8>> {
    // Gap may include the surrounding '<' '>' and whitespace; keep hex digits only.
    let clean: Vec<u8> = hex.iter().copied().filter(|b| b.is_ascii_hexdigit()).collect();
    let clean = if clean.len() % 2 == 1 {
        &clean[..clean.len() - 1]
    } else {
        &clean[..]
    };
    let mut out = Vec::with_capacity(clean.len() / 2);
    for pair in clean.chunks(2) {
        let hi = hex_val(pair[0])?;
        let lo = hex_val(pair[1])?;
        out.push((hi << 4) | lo);
    }
    // Trim trailing zero padding from the placeholder.
    while out.last() == Some(&0) {
        out.pop();
    }
    Some(out)
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn last_eof(bytes: &[u8]) -> usize {
    let needle = b"%%EOF";
    bytes
        .windows(needle.len())
        .rposition(|w| w == needle)
        .map(|p| p + needle.len())
        .unwrap_or(bytes.len())
}
