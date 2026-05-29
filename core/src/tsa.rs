//! RFC 3161 timestamp client. POSTs a TimeStampReq, returns the TimeStampToken.

use crate::cms;

pub fn fetch_token(tsa_url: &str, signature: &[u8]) -> Result<Vec<u8>, String> {
    let req = cms::timestamp_request(signature);
    let resp = ureq::post(tsa_url)
        .set("Content-Type", "application/timestamp-query")
        .timeout(std::time::Duration::from_secs(15))
        .send_bytes(&req)
        .map_err(|e| format!("TSA request failed: {e}"))?;

    let mut body = Vec::new();
    use std::io::Read;
    resp.into_reader()
        .read_to_end(&mut body)
        .map_err(|e| format!("TSA read failed: {e}"))?;

    cms::extract_tst(&body).ok_or_else(|| "TSA response had no token".to_string())
}
