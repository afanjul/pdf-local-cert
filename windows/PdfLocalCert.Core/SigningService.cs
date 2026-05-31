using System.Text.Json;

namespace PdfLocalCert.Core;

/// <summary>
/// Orchestrates the external-signer round-trip: prepare → CNG sign → finalize, plus
/// verify. Ports SigningCoordinator.swift and the validated Phase 3 spike flow.
/// </summary>
public sealed class SigningService
{
    /// <summary>Sign a PDF. The private key never leaves the Windows store.</summary>
    public SignResult Sign(SignRequest req)
    {
        if (req.Cert.IsExpired) throw new SigningException("CERT_EXPIRED", "certificate is expired");

        var workDir = Path.Combine(Path.GetTempPath(), "pdflocalcert-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workDir);
        var client = new CoreClient { WorkDir = workDir };

        var chain = IdentityStore.BuildChain(req.Cert.Certificate);

        // ── prepare ──
        var placements = new List<object>();
        foreach (var p in req.Placements)
        {
            placements.Add(new Dictionary<string, object>
            {
                ["page"] = p.Page, ["x"] = p.X, ["y"] = p.Y, ["w"] = p.W, ["h"] = p.H,
                ["lines"] = p.Lines,
                ["border"] = p.Border,
                ["background"] = p.Background,
            });
        }
        var prepareReq = new Dictionary<string, object>
        {
            ["op"] = "prepare",
            ["pdf"] = req.PdfPath,
            ["cert_chain"] = chain.Select(Convert.ToBase64String).ToArray(),
            ["placements"] = placements,
            ["work_dir"] = workDir,
        };
        if (!string.IsNullOrEmpty(req.Reason)) prepareReq["reason"] = req.Reason;
        if (!string.IsNullOrEmpty(req.Location)) prepareReq["location"] = req.Location;
        if (!string.IsNullOrEmpty(req.SignerName)) prepareReq["name"] = req.SignerName;
        if (!string.IsNullOrEmpty(req.TsaUrl)) prepareReq["tsa_url"] = req.TsaUrl;

        var prep = client.Request(prepareReq);
        ThrowIfError(prep);
        if (prep.GetProperty("status").GetString() != "need_signature")
            throw new SigningException("CORE_CRASH", "invalid prepare response");

        var handle = prep.GetProperty("handle").GetString()!;
        var sigAlg = prep.GetProperty("sig_alg").GetString()!;
        var tbs = Convert.FromBase64String(prep.GetProperty("digest").GetString()!);

        // ── CNG sign (key stays in the store) ──
        var signature = CngSigner.Sign(req.Cert.Certificate, tbs, sigAlg);

        // Independent self-check: the core's verify is RSA-only, so this is the only
        // crypto proof for ECDSA that the bytes we hand back are a sound signature.
        if (!CngSigner.SelfVerify(req.Cert.Certificate, tbs, signature, sigAlg))
            throw new SigningException("CORE_CRASH", "signature failed self-verification");

        // ── finalize ──
        var fin = client.Request(new Dictionary<string, object>
        {
            ["op"] = "finalize",
            ["handle"] = handle,
            ["signature"] = Convert.ToBase64String(signature),
        });
        ThrowIfError(fin);

        return new SignResult
        {
            OutputPath = fin.GetProperty("out").GetString()!,
            PadesLevel = fin.TryGetProperty("pades_level", out var l) ? l.GetString() ?? "B-B" : "B-B",
            SignerCommonName = fin.TryGetProperty("signer_cn", out var s) ? s.GetString() ?? req.Cert.CommonName : req.Cert.CommonName,
        };
    }

    /// <summary>Verify all signatures in a PDF. Ports SigningCoordinator.verify.</summary>
    public List<VerificationResult> Verify(string pdfPath)
    {
        var client = new CoreClient();
        var resp = client.Request(new Dictionary<string, object> { ["op"] = "verify", ["pdf"] = pdfPath });
        ThrowIfError(resp);

        var results = new List<VerificationResult>();
        if (resp.TryGetProperty("signatures", out var sigs) && sigs.ValueKind == JsonValueKind.Array)
        {
            foreach (var s in sigs.EnumerateArray())
            {
                results.Add(new VerificationResult
                {
                    Valid = s.TryGetProperty("valid", out var v) && v.GetBoolean(),
                    Signer = s.TryGetProperty("signer_cn", out var sc) ? sc.GetString() ?? "(unknown)" : "(unknown)",
                    Issuer = s.TryGetProperty("issuer_cn", out var ic) ? ic.GetString() ?? "(unknown)" : "(unknown)",
                    Level = s.TryGetProperty("pades_level", out var pl) ? pl.GetString() ?? "?" : "?",
                    HasTimestamp = s.TryGetProperty("has_timestamp", out var ts) && ts.GetBoolean(),
                    Detail = s.TryGetProperty("detail", out var d) ? d.GetString() ?? "" : "",
                });
            }
        }
        return results;
    }

    private static void ThrowIfError(JsonElement resp)
    {
        if (resp.TryGetProperty("status", out var st) && st.GetString() == "error")
        {
            var code = resp.TryGetProperty("code", out var c) ? c.GetString() ?? "CORE_CRASH" : "CORE_CRASH";
            var msg = resp.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "";
            throw new SigningException(code, msg);
        }
    }
}
