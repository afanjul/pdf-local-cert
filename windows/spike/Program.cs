using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;

// ─────────────────────────────────────────────────────────────────────────────
//  PDF Local Cert — Windows crypto spike (Phase 3)
//
//  De-risks the Windows signing path before the WinUI shell exists. Proves, end
//  to end, that we can:
//    3.1  enumerate signing identities from the Windows cert store
//    3.2  sign the core's TBS bytes via CNG (RSA + ECDSA)
//    3.3  hand the core an ECDSA signature in the DER form its CMS expects
//    3.4  assemble a leaf-first cert chain (X509Chain + DN-normalized walk)
//    3.5  drive a real prepare → CNG sign → finalize → verify round-trip
//    3.6  request a B-T timestamp from a real RFC 3161 TSA
//
//  KEY CONTRACT NOTE (verified against core/src/sign.rs:281):
//  the protocol's `digest` field is NOT a pre-hashed digest — it carries the
//  FULL DER-encoded SignedAttributes (the to-be-signed message). The macOS shell
//  signs it with *message* algorithms (rsaSignatureMessagePKCS1v15SHA256 /
//  ecdsaSignatureMessageX962SHA256), i.e. hash-THEN-sign. So on Windows we MUST
//  use SignData (which hashes internally), NOT SignHash. SignHash would sign the
//  raw ~250 DER bytes as if they were a SHA-256 digest and silently produce an
//  invalid signature.
//
//  ECDSA: macOS uses X962 (DER) and the core's CMS expects an
//  ecdsa-with-SHA256 signature as a DER SEQUENCE{r,s}. .NET's default ECDSA
//  output is raw P1363 (r‖s); we request DSASignatureFormat.Rfc3279DerSequence
//  so the core gets DER directly (task 3.3, native in .NET 8).
// ─────────────────────────────────────────────────────────────────────────────

return Cli.Run(args);

static class Cli
{
    public static int Run(string[] args)
    {
        try
        {
            var cmd = args.Length > 0 ? args[0] : "help";
            switch (cmd)
            {
                case "list":
                    IdentityStore.Print();
                    return 0;
                case "sign":
                    return SignFlow.Run(args);
                case "ping":
                    Console.WriteLine(Core.Ping() ? "core ping OK" : "core ping FAILED");
                    return 0;
                default:
                    Console.WriteLine(
                        "usage:\n" +
                        "  plc-spike list\n" +
                        "  plc-spike ping\n" +
                        "  plc-spike sign <pdf> <thumbprint> [--tsa <url>] [--invisible]\n");
                    return 1;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"FATAL: {ex.Message}\n{ex}");
            return 2;
        }
    }
}

// ── 3.1  Identity enumeration ────────────────────────────────────────────────
static class IdentityStore
{
    /// All certs in CurrentUser\My that hold a private key and permit signing.
    public static List<X509Certificate2> LoadSigningIdentities()
    {
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
        var result = new List<X509Certificate2>();
        foreach (var c in store.Certificates)
        {
            if (!c.HasPrivateKey) continue;
            if (!KeyUsageAllowsSigning(c)) continue;
            result.Add(c);
        }
        // Most recent expiry first (mirrors the macOS picker order).
        result.Sort((a, b) => b.NotAfter.CompareTo(a.NotAfter));
        return result;
    }

    public static void Print()
    {
        var ids = LoadSigningIdentities();
        if (ids.Count == 0) { Console.WriteLine("(no signing identities in CurrentUser\\My)"); return; }
        for (int i = 0; i < ids.Count; i++)
        {
            var c = ids[i];
            var expired = c.NotAfter < DateTime.Now;
            Console.WriteLine(
                $"[{i}] {Dn.Cn(c.Subject)}\n" +
                $"      issuer:    {Dn.Cn(c.Issuer)}\n" +
                $"      alg:       {c.GetKeyAlgorithmFriendly()}\n" +
                $"      notAfter:  {c.NotAfter:yyyy-MM-dd}{(expired ? "  (EXPIRED)" : "")}\n" +
                $"      thumb:     {c.Thumbprint}");
        }
    }

    /// True if KeyUsage permits digitalSignature or nonRepudiation, or is absent.
    /// Mirrors IdentityStore.keyUsageAllowsSigning on macOS.
    static bool KeyUsageAllowsSigning(X509Certificate2 cert)
    {
        foreach (var ext in cert.Extensions)
        {
            if (ext is X509KeyUsageExtension ku)
            {
                var allowed = X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation;
                return (ku.KeyUsages & allowed) != 0;
            }
        }
        return true; // no KeyUsage extension: allow
    }
}

// ── 3.2 / 3.3  CNG signing callback ──────────────────────────────────────────
static class CngSigner
{
    /// Sign the core's TBS bytes. `sigAlg` comes straight from the prepare
    /// response ("rsa-pkcs1-sha256" | "ecdsa-sha256").
    ///
    /// IMPORTANT: `tbs` is the full SignedAttributes DER, NOT a hash — so we call
    /// SignData (hash-then-sign), never SignHash. See file header.
    public static byte[] Sign(X509Certificate2 cert, byte[] tbs, string sigAlg)
    {
        switch (sigAlg)
        {
            case "rsa-pkcs1-sha256":
                using (var rsa = cert.GetRSAPrivateKey()
                    ?? throw new InvalidOperationException("cert has no RSA private key"))
                {
                    return rsa.SignData(tbs, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

            case "ecdsa-sha256":
                using (var ec = cert.GetECDsaPrivateKey()
                    ?? throw new InvalidOperationException("cert has no ECDSA private key"))
                {
                    // CNG natively returns P1363 (raw r‖s). The core's CMS wants a
                    // DER SEQUENCE{r,s}; .NET 8 emits that directly when asked.
                    return ec.SignData(tbs, HashAlgorithmName.SHA256,
                        DSASignatureFormat.Rfc3279DerSequence);
                }

            default:
                throw new NotSupportedException($"unexpected sig_alg from core: {sigAlg}");
        }
    }

    /// Verify a signature against the cert's PUBLIC key, mirroring the exact
    /// algorithm + format we signed with. Independent of the core/Adobe.
    public static bool SelfVerify(X509Certificate2 cert, byte[] tbs, byte[] sig, string sigAlg)
    {
        switch (sigAlg)
        {
            case "rsa-pkcs1-sha256":
                using (var rsa = cert.GetRSAPublicKey()
                    ?? throw new InvalidOperationException("cert has no RSA public key"))
                {
                    return rsa.VerifyData(tbs, sig, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

            case "ecdsa-sha256":
                using (var ec = cert.GetECDsaPublicKey()
                    ?? throw new InvalidOperationException("cert has no ECDSA public key"))
                {
                    return ec.VerifyData(tbs, sig, HashAlgorithmName.SHA256,
                        DSASignatureFormat.Rfc3279DerSequence);
                }

            default:
                throw new NotSupportedException($"unexpected sig_alg: {sigAlg}");
        }
    }
}

// ── 3.4  Cert-chain assembly ─────────────────────────────────────────────────
static class ChainBuilder
{
    /// Leaf-first DER list (signer, intermediates, root if present). Embedded in
    /// the CMS so verifiers can build a trust path from the signature alone.
    /// Tries X509Chain first, then a manual issuer→subject DN walk, and keeps
    /// whichever path is longer — mirrors IdentityStore.chainDER on macOS, which
    /// exists because FNMT/UANATACA reissued intermediates break the automatic
    /// AKI-based linkage.
    public static List<byte[]> Build(X509Certificate2 leaf)
    {
        var viaChain = new List<X509Certificate2>();
        using (var chain = new X509Chain())
        {
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllFlags; // populate even if untrusted
            chain.Build(leaf); // ignore bool: we want the elements regardless
            foreach (var el in chain.ChainElements) viaChain.Add(el.Certificate);
        }

        var viaDn = WalkByDn(leaf);
        var best = viaDn.Count >= viaChain.Count ? viaDn : viaChain;
        if (best.Count == 0) best = new List<X509Certificate2> { leaf };
        return best.Select(c => c.RawData).ToList();
    }

    /// Walk leaf → issuer by matching DER-encoded DNs against every cert in
    /// CurrentUser\My and \CA, stopping at a self-signed root or a dead end.
    static List<X509Certificate2> WalkByDn(X509Certificate2 leaf)
    {
        var pool = CandidatePool();
        var chain = new List<X509Certificate2> { leaf };
        var seen = new HashSet<string> { leaf.Thumbprint };
        var current = leaf;

        while (chain.Count < 10)
        {
            var issuerDn = current.IssuerName.RawData;
            var subjectDn = current.SubjectName.RawData;
            if (issuerDn.AsSpan().SequenceEqual(subjectDn)) break; // self-signed root

            var next = pool.FirstOrDefault(c =>
                c.SubjectName.RawData.AsSpan().SequenceEqual(issuerDn) &&
                !seen.Contains(c.Thumbprint));
            if (next is null) break;

            chain.Add(next);
            seen.Add(next.Thumbprint);
            current = next;
        }
        return chain;
    }

    static List<X509Certificate2> CandidatePool()
    {
        var pool = new List<X509Certificate2>();
        foreach (var (name, loc) in new[]
        {
            (StoreName.CertificateAuthority, StoreLocation.CurrentUser),
            (StoreName.CertificateAuthority, StoreLocation.LocalMachine),
            (StoreName.My, StoreLocation.CurrentUser),
            (StoreName.Root, StoreLocation.LocalMachine),
        })
        {
            try
            {
                using var s = new X509Store(name, loc);
                s.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
                foreach (var c in s.Certificates) pool.Add(c);
            }
            catch { /* store may not exist; ignore */ }
        }
        return pool;
    }
}

// ── 3.5 / 3.6  End-to-end sign flow ──────────────────────────────────────────
static class SignFlow
{
    public static int Run(string[] args)
    {
        if (args.Length < 3)
        {
            Console.Error.WriteLine("usage: plc-spike sign <pdf> <thumbprint> [--tsa <url>] [--invisible]");
            return 1;
        }
        var pdf = Path.GetFullPath(args[1]);
        var thumb = args[2].Replace(" ", "").ToUpperInvariant();
        string? tsa = null;
        bool invisible = false;
        for (int i = 3; i < args.Length; i++)
        {
            if (args[i] == "--tsa" && i + 1 < args.Length) tsa = args[++i];
            else if (args[i] == "--invisible") invisible = true;
        }

        if (!File.Exists(pdf)) { Console.Error.WriteLine($"no such pdf: {pdf}"); return 1; }

        var cert = IdentityStore.LoadSigningIdentities()
            .FirstOrDefault(c => c.Thumbprint == thumb)
            ?? throw new InvalidOperationException($"no signing identity with thumbprint {thumb}");
        if (cert.NotAfter < DateTime.Now)
            throw new InvalidOperationException("certificate is expired");

        Console.WriteLine($"signer:  {Dn.Cn(cert.Subject)} ({cert.GetKeyAlgorithmFriendly()})");

        var workDir = Path.Combine(Path.GetTempPath(), "plc-spike-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workDir);
        // The core's finalize recovers prepare's state file from $PDFLOCALCERT_WORK
        // (see core/src/sign.rs:load_state). The macOS CoreClient sets this on every
        // spawn; we must too, since each request is a fresh process.
        Core.WorkDir = workDir;

        var chain = ChainBuilder.Build(cert);
        Console.WriteLine($"chain:   {chain.Count} cert(s)");

        // ── prepare ──
        var placements = new List<object>();
        if (!invisible)
        {
            placements.Add(new Dictionary<string, object>
            {
                ["page"] = 0, ["x"] = 72.0, ["y"] = 72.0, ["w"] = 220.0, ["h"] = 60.0,
                ["lines"] = new[] { $"Firmado por: {Dn.Cn(cert.Subject)}", "Spike test signature" },
                ["border"] = true, ["background"] = true,
            });
        }
        var prepareReq = new Dictionary<string, object>
        {
            ["op"] = "prepare",
            ["pdf"] = pdf,
            ["cert_chain"] = chain.Select(Convert.ToBase64String).ToArray(),
            ["placements"] = placements,
            ["work_dir"] = workDir,
            ["reason"] = "Spike test",
        };
        if (!string.IsNullOrEmpty(tsa)) prepareReq["tsa_url"] = tsa;

        var prep = Core.Request(prepareReq);
        RequireOk(prep, "prepare");
        var status = prep.GetProperty("status").GetString();
        if (status != "need_signature")
            throw new InvalidOperationException($"unexpected prepare status: {status}");

        var handle = prep.GetProperty("handle").GetString()!;
        var sigAlg = prep.GetProperty("sig_alg").GetString()!;
        var tbs = Convert.FromBase64String(prep.GetProperty("digest").GetString()!);
        Console.WriteLine($"prepare: ok  sig_alg={sigAlg}  tbs={tbs.Length}B  handle={handle}");

        // ── CNG sign (key never leaves the store) ──
        var signature = CngSigner.Sign(cert, tbs, sigAlg);
        Console.WriteLine($"sign:    ok  {signature.Length}B" +
            (sigAlg == "ecdsa-sha256" ? " (DER SEQUENCE{r,s})" : ""));

        // Independent self-check: verify the signature against the cert's PUBLIC
        // key over the TBS, using the same algorithm/format we sent the core.
        // This proves the bytes (esp. the ECDSA P1363→DER conversion) are a sound
        // signature WITHOUT trusting the core or Adobe — the core's verify is
        // RSA-only (verify.rs:68), so for ECDSA this is our only crypto proof here.
        if (!CngSigner.SelfVerify(cert, tbs, signature, sigAlg))
            throw new InvalidOperationException("self-verify FAILED: signature does not verify against the public key");
        Console.WriteLine("selfchk: ok  (signature verifies against cert public key)");

        // ── finalize ──
        var fin = Core.Request(new Dictionary<string, object>
        {
            ["op"] = "finalize",
            ["handle"] = handle,
            ["signature"] = Convert.ToBase64String(signature),
        });
        RequireOk(fin, "finalize");
        var outPath = fin.GetProperty("out").GetString()!;
        var pades = fin.GetProperty("pades_level").GetString();
        Console.WriteLine($"finalize:ok  level={pades}  out={outPath}");

        // ── verify (core's own check; fast pass/fail before Adobe) ──
        var ver = Core.Request(new Dictionary<string, object> { ["op"] = "verify", ["pdf"] = outPath });
        RequireOk(ver, "verify");
        var sigs = ver.GetProperty("signatures");
        Console.WriteLine($"verify:  {sigs.GetArrayLength()} signature(s)");
        foreach (var s in sigs.EnumerateArray())
        {
            Console.WriteLine(
                $"   valid={s.GetProperty("valid").GetBoolean()} " +
                $"signer={s.GetProperty("signer_cn").GetString()} " +
                $"issuer={s.GetProperty("issuer_cn").GetString()} " +
                $"level={s.GetProperty("pades_level").GetString()} " +
                $"ts={s.GetProperty("has_timestamp").GetBoolean()} " +
                $"wholeFile={s.GetProperty("byte_range_covers_whole_file").GetBoolean()}");
            Console.WriteLine($"   detail: {s.GetProperty("detail").GetString()}");
        }

        var anyValid = sigs.EnumerateArray().Any(s => s.GetProperty("valid").GetBoolean());
        Console.WriteLine(anyValid ? "\nRESULT: PASS (core verifies the signature)" : "\nRESULT: FAIL");
        Console.WriteLine($"open in Adobe to confirm: {outPath}");
        return anyValid ? 0 : 3;
    }

    static void RequireOk(JsonElement resp, string stage)
    {
        if (resp.TryGetProperty("status", out var st) && st.GetString() == "error")
        {
            var code = resp.TryGetProperty("code", out var c) ? c.GetString() : "?";
            var msg = resp.TryGetProperty("message", out var m) ? m.GetString() : "";
            throw new InvalidOperationException($"{stage} failed [{code}]: {msg}");
        }
    }
}

// ── Core client: spawn the exe, one request line / one response line ─────────
static class Core
{
    /// Set by the sign flow so the core's finalize can recover prepare's state
    /// file from $PDFLOCALCERT_WORK (core/src/sign.rs:load_state).
    public static string? WorkDir;

    static string ExePath()
    {
        // Dev layout: <repo>/core/target/x86_64-pc-windows-msvc/release/.
        // The spike binary runs from windows/spike/bin/...; walk up to repo root.
        var dir = AppContext.BaseDirectory;
        for (int i = 0; i < 8 && dir != null; i++)
        {
            var candidate = Path.Combine(dir,
                "core", "target", "x86_64-pc-windows-msvc", "release", "pdflocalcert-core.exe");
            if (File.Exists(candidate)) return candidate;
            dir = Directory.GetParent(dir)?.FullName;
        }
        // Fallback: the copy we staged at C:\plc during the 2.4 ping check.
        var local = @"C:\plc\pdflocalcert-core.exe";
        if (File.Exists(local)) return local;
        throw new FileNotFoundException("pdflocalcert-core.exe not found (built? on PATH?)");
    }

    public static JsonElement Request(object req)
    {
        var psi = new ProcessStartInfo(ExePath())
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            StandardOutputEncoding = new UTF8Encoding(false),
        };
        if (WorkDir != null) psi.Environment["PDFLOCALCERT_WORK"] = WorkDir;
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("failed to spawn core");
        var line = JsonSerializer.Serialize(req);
        p.StandardInput.Write(line);
        p.StandardInput.Write('\n');
        p.StandardInput.Flush();
        p.StandardInput.Close();
        var stdout = p.StandardOutput.ReadToEnd();
        var stderr = p.StandardError.ReadToEnd();
        p.WaitForExit();

        var first = stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (first is null)
            throw new InvalidOperationException($"core returned no response. stderr: {stderr}");
        return JsonDocument.Parse(first).RootElement.Clone();
    }

    public static bool Ping()
    {
        var resp = Request(new Dictionary<string, object> { ["op"] = "ping" });
        return resp.TryGetProperty("pong", out var pong) && pong.GetBoolean();
    }
}

// ── tiny DN helper ───────────────────────────────────────────────────────────
static class Dn
{
    /// Pull the CN out of an RFC 2253 distinguished-name string.
    public static string Cn(string distinguishedName)
    {
        foreach (var part in distinguishedName.Split(','))
        {
            var t = part.Trim();
            if (t.StartsWith("CN=", StringComparison.OrdinalIgnoreCase))
                return t[3..];
        }
        return distinguishedName;
    }
}

static class CertExt
{
    public static string GetKeyAlgorithmFriendly(this X509Certificate2 c)
        => c.GetECDsaPublicKey() != null ? "ECDSA" :
           c.GetRSAPublicKey() != null ? "RSA" :
           c.PublicKey.Oid.FriendlyName ?? c.PublicKey.Oid.Value ?? "?";
}
