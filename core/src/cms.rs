//! Minimal, explicit DER + CMS SignedData builder for detached PAdES signatures.
//!
//! Hand-rolled TLV encoding keeps full control of the external/callback signer
//! flow: we build the SignedAttributes, hand them out to be signed, then splice
//! the returned signature into a CMS SignedData without re-encoding surprises.

use sha2::{Digest, Sha256};
use x509_cert::Certificate;
use der::{Decode, Encode};

// ---------- DER primitives ----------

fn der_len(n: usize) -> Vec<u8> {
    if n < 0x80 {
        vec![n as u8]
    } else {
        let mut bytes = Vec::new();
        let mut v = n;
        while v > 0 {
            bytes.insert(0, (v & 0xff) as u8);
            v >>= 8;
        }
        let mut out = vec![0x80 | bytes.len() as u8];
        out.extend_from_slice(&bytes);
        out
    }
}

fn tlv(tag: u8, content: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(content.len() + 4);
    out.push(tag);
    out.extend_from_slice(&der_len(content.len()));
    out.extend_from_slice(content);
    out
}

fn seq(parts: &[&[u8]]) -> Vec<u8> {
    tlv(0x30, &parts.concat())
}

/// SET OF with DER ordering (elements sorted by their full encoding).
fn set_of(mut elems: Vec<Vec<u8>>) -> Vec<u8> {
    elems.sort();
    tlv(0x31, &elems.concat())
}

fn oid(content: &[u8]) -> Vec<u8> {
    tlv(0x06, content)
}
fn octet(content: &[u8]) -> Vec<u8> {
    tlv(0x04, content)
}
fn int_u8(v: u8) -> Vec<u8> {
    tlv(0x02, &[v])
}
fn boolean(v: bool) -> Vec<u8> {
    tlv(0x01, &[if v { 0xff } else { 0x00 }])
}
fn null() -> Vec<u8> {
    tlv(0x05, &[])
}
/// Context tag, constructed: [n] over content.
fn ctx_constructed(n: u8, content: &[u8]) -> Vec<u8> {
    tlv(0xA0 | n, content)
}

// ---------- OID byte payloads (content only) ----------

const OID_DATA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01];
const OID_SIGNED_DATA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02];
const OID_ATTR_CONTENT_TYPE: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03];
const OID_ATTR_MESSAGE_DIGEST: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04];
const OID_SIGNING_CERT_V2: &[u8] =
    &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x02, 0x2f];
const OID_TIMESTAMP_TOKEN: &[u8] =
    &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x02, 0x0e];
const OID_SHA256: &[u8] = &[0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01];
const OID_RSA_ENCRYPTION: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01];
const OID_ECDSA_SHA256: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02];
const OID_EC_PUBLIC_KEY: &[u8] = &[0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];

pub enum KeyKind {
    Rsa,
    Ecdsa,
}

/// Inspect a DER certificate, return the signing key kind and the signer CN.
pub fn inspect_cert(cert_der: &[u8]) -> Result<(KeyKind, String), String> {
    let cert = Certificate::from_der(cert_der).map_err(|e| format!("cert parse: {e}"))?;
    let spki_alg = cert
        .tbs_certificate
        .subject_public_key_info
        .algorithm
        .oid
        .as_bytes()
        .to_vec();
    let kind = if spki_alg == OID_EC_PUBLIC_KEY {
        KeyKind::Ecdsa
    } else {
        KeyKind::Rsa
    };
    let cn = cn_of(&cert.tbs_certificate.subject.to_der().unwrap_or_default());
    Ok((kind, cn))
}

/// Extract the first commonName (OID 2.5.4.3) printable/UTF8 string from a Name DER.
pub fn cn_of(name_der: &[u8]) -> String {
    // 2.5.4.3
    const CN: &[u8] = &[0x55, 0x04, 0x03];
    find_cn(name_der, CN).unwrap_or_else(|| "(unknown)".to_string())
}

fn find_cn(buf: &[u8], cn_oid: &[u8]) -> Option<String> {
    // Walk TLVs recursively; when we see an AttributeTypeAndValue SEQ whose
    // first element is the CN OID, return the following string value.
    let mut i = 0;
    while i < buf.len() {
        let (tag, len, hdr) = read_tlv_header(&buf[i..])?;
        let content = &buf[i + hdr..i + hdr + len];
        if tag == 0x30 || tag == 0x31 {
            // try to match AttributeTypeAndValue: OID then string
            if let Some((t0, l0, h0)) = read_tlv_header(content) {
                if t0 == 0x06 && &content[h0..h0 + l0] == cn_oid {
                    let rest = &content[h0 + l0..];
                    if let Some((ts, ls, hs)) = read_tlv_header(rest) {
                        if ts == 0x0c || ts == 0x13 || ts == 0x14 {
                            return String::from_utf8(rest[hs..hs + ls].to_vec()).ok();
                        }
                    }
                }
            }
            if let Some(found) = find_cn(content, cn_oid) {
                return Some(found);
            }
        }
        i += hdr + len;
    }
    None
}

/// Return (tag, content_len, header_len).
pub fn read_tlv_header(buf: &[u8]) -> Option<(u8, usize, usize)> {
    if buf.len() < 2 {
        return None;
    }
    let tag = buf[0];
    let first = buf[1];
    if first < 0x80 {
        Some((tag, first as usize, 2))
    } else {
        let n = (first & 0x7f) as usize;
        if n == 0 || buf.len() < 2 + n {
            return None;
        }
        let mut len = 0usize;
        for &b in &buf[2..2 + n] {
            len = (len << 8) | b as usize;
        }
        Some((tag, len, 2 + n))
    }
}

// ---------- SignedAttributes ----------

/// Build the DER SET OF SignedAttributes (tag 0x31) that the shell signs.
/// Attributes: contentType=id-data, messageDigest, signingCertificateV2.
pub fn signed_attributes(doc_digest: &[u8], signer_cert_der: &[u8]) -> Vec<u8> {
    let content_type = seq(&[&oid(OID_ATTR_CONTENT_TYPE), &set_of(vec![oid(OID_DATA)])]);

    let message_digest = seq(&[
        &oid(OID_ATTR_MESSAGE_DIGEST),
        &set_of(vec![octet(doc_digest)]),
    ]);

    // ESSCertIDv2 { certHash } (hashAlgorithm defaults to sha256, omitted)
    let cert_hash = Sha256::digest(signer_cert_der);
    let ess_cert_id = seq(&[&octet(&cert_hash)]);
    let certs_seq = seq(&[&ess_cert_id]);
    let signing_cert_v2 = seq(&[&certs_seq]);
    let signing_cert_attr =
        seq(&[&oid(OID_SIGNING_CERT_V2), &set_of(vec![signing_cert_v2])]);

    set_of(vec![content_type, message_digest, signing_cert_attr])
}

// ---------- SignerInfo / SignedData / ContentInfo ----------

fn issuer_and_serial(cert_der: &[u8]) -> Result<Vec<u8>, String> {
    let cert = Certificate::from_der(cert_der).map_err(|e| format!("cert parse: {e}"))?;
    let issuer = cert
        .tbs_certificate
        .issuer
        .to_der()
        .map_err(|e| e.to_string())?;
    let serial = cert
        .tbs_certificate
        .serial_number
        .to_der()
        .map_err(|e| e.to_string())?;
    Ok(seq(&[&issuer, &serial]))
}

fn digest_algo() -> Vec<u8> {
    seq(&[&oid(OID_SHA256)])
}

fn sig_algo(kind: &KeyKind) -> Vec<u8> {
    match kind {
        KeyKind::Rsa => seq(&[&oid(OID_RSA_ENCRYPTION), &null()]),
        KeyKind::Ecdsa => seq(&[&oid(OID_ECDSA_SHA256)]),
    }
}

/// Assemble the full CMS ContentInfo (SignedData) for a detached PAdES signature.
/// `signed_attrs_der` is the SET OF (tag 0x31) produced by [`signed_attributes`].
/// `signature` is the raw signature over those bytes (PKCS1 or DER-ECDSA).
/// `tst` is an optional RFC 3161 timestamp token (ContentInfo) to embed.
pub fn build_cms(
    chain_der: &[Vec<u8>],
    signed_attrs_der: &[u8],
    signature: &[u8],
    kind: &KeyKind,
    tst: Option<&[u8]>,
) -> Result<Vec<u8>, String> {
    let signer_cert = &chain_der[0];

    // signedAttrs in SignerInfo are [0] IMPLICIT: retag SET (0x31) -> 0xA0.
    let mut implicit_attrs = signed_attrs_der.to_vec();
    implicit_attrs[0] = 0xA0;

    let sid = issuer_and_serial(signer_cert)?;

    let mut signer_info_parts: Vec<Vec<u8>> = vec![
        int_u8(1), // version (issuerAndSerialNumber => 1)
        sid,
        digest_algo(),
        implicit_attrs,
        sig_algo(kind),
        octet(signature),
    ];

    if let Some(token) = tst {
        // unsignedAttrs [1] IMPLICIT SET OF { timeStampToken attribute }
        let ts_attr = seq(&[&oid(OID_TIMESTAMP_TOKEN), &set_of(vec![token.to_vec()])]);
        let unsigned = set_of(vec![ts_attr]);
        let mut unsigned_ctx = unsigned;
        unsigned_ctx[0] = 0xA1; // [1] IMPLICIT
        signer_info_parts.push(unsigned_ctx);
    }

    let signer_info_refs: Vec<&[u8]> = signer_info_parts.iter().map(|v| v.as_slice()).collect();
    let signer_info = seq(&signer_info_refs);

    // certificates [0] IMPLICIT SET OF CertificateChoices (each cert DER is a SEQUENCE)
    let certs_concat: Vec<u8> = chain_der.concat();
    let certificates = ctx_constructed(0, &certs_concat);

    let digest_algos = set_of(vec![digest_algo()]);
    let encap = seq(&[&oid(OID_DATA)]); // detached: no eContent
    let signer_infos = set_of(vec![signer_info]);

    let signed_data = seq(&[
        &int_u8(1), // version
        &digest_algos,
        &encap,
        &certificates,
        &signer_infos,
    ]);

    let content_info = seq(&[&oid(OID_SIGNED_DATA), &ctx_constructed(0, &signed_data)]);
    Ok(content_info)
}

/// Build an RFC 3161 TimeStampReq for the SHA-256 of `data`, certReq=true.
pub fn timestamp_request(data: &[u8]) -> Vec<u8> {
    let hash = Sha256::digest(data);
    let message_imprint = seq(&[&seq(&[&oid(OID_SHA256), &null()]), &octet(&hash)]);
    seq(&[&int_u8(1), &message_imprint, &boolean(true)])
}

/// Extract the TimeStampToken (a ContentInfo SEQUENCE) from a TimeStampResp.
/// TimeStampResp ::= SEQ { status PKIStatusInfo, timeStampToken ContentInfo OPTIONAL }
pub fn extract_tst(resp: &[u8]) -> Option<Vec<u8>> {
    let (tag, len, hdr) = read_tlv_header(resp)?;
    if tag != 0x30 {
        return None;
    }
    let body = &resp[hdr..hdr + len];
    // first element: PKIStatusInfo (SEQ)
    let (_, l0, h0) = read_tlv_header(body)?;
    let after = &body[h0 + l0..];
    // second element: the token ContentInfo (SEQ)
    let (t1, l1, h1) = read_tlv_header(after)?;
    if t1 != 0x30 {
        return None;
    }
    Some(after[..h1 + l1].to_vec())
}
