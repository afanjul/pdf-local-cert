using PdfLocalCert.Core;

// ─────────────────────────────────────────────────────────────────────────────
//  PDF Local Cert — Windows crypto spike (Phase 3), now a thin CLI over the
//  shared PdfLocalCert.Core library. Re-running it exercises the SAME code the
//  WinUI shell uses (IdentityStore / CngSigner / SigningService), so the spike
//  doubles as a headless integration test of the promoted services.
//
//  Validated on the Win11 VM: RSA + ECDSA round-trips PASS, B-T timestamp from a
//  live RFC 3161 TSA works. See windows/README.md for the contract findings.
// ─────────────────────────────────────────────────────────────────────────────

return Run(args);

static int Run(string[] args)
{
    try
    {
        var cmd = args.Length > 0 ? args[0] : "help";
        switch (cmd)
        {
            case "list": return List();
            case "ping": Console.WriteLine(new CoreClient().Ping() ? "core ping OK" : "core ping FAILED"); return 0;
            case "sign": return Sign(args);
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
        Console.Error.WriteLine($"FATAL: {ex.Message}");
        return 2;
    }
}

static int List()
{
    var ids = IdentityStore.LoadSigningIdentities();
    if (ids.Count == 0) { Console.WriteLine("(no signing identities in CurrentUser\\My)"); return 0; }
    foreach (var c in ids)
    {
        Console.WriteLine(
            $"  {c.CommonName}\n" +
            $"     issuer:   {c.Issuer}\n" +
            $"     alg:      {c.KeyAlgorithm}  canSign={c.CanSign}\n" +
            $"     notAfter: {c.NotAfter:yyyy-MM-dd}{(c.IsExpired ? "  (EXPIRED)" : "")}\n" +
            $"     thumb:    {c.Thumbprint}");
    }
    return 0;
}

static int Sign(string[] args)
{
    if (args.Length < 3)
    {
        Console.Error.WriteLine("usage: plc-spike sign <pdf> <thumbprint> [--tsa <url>] [--invisible]");
        return 1;
    }
    var pdf = Path.GetFullPath(args[1]);
    var thumb = args[2].Replace(" ", "").ToUpperInvariant();
    string? tsa = null;
    var invisible = false;
    for (var i = 3; i < args.Length; i++)
    {
        if (args[i] == "--tsa" && i + 1 < args.Length) tsa = args[++i];
        else if (args[i] == "--invisible") invisible = true;
    }
    if (!File.Exists(pdf)) { Console.Error.WriteLine($"no such pdf: {pdf}"); return 1; }

    var cert = IdentityStore.LoadSigningIdentities().FirstOrDefault(c => c.Thumbprint == thumb)
        ?? throw new InvalidOperationException($"no signing identity with thumbprint {thumb}");
    Console.WriteLine($"signer:  {cert.CommonName} ({cert.KeyAlgorithm})");

    var placements = invisible
        ? Array.Empty<PlacementSpec>()
        : new[]
        {
            new PlacementSpec
            {
                Page = 0, X = 72, Y = 72, W = 220, H = 60,
                Lines = new[] { $"Firmado por: {cert.CommonName}", "Spike test signature" },
                Border = true, Background = true,
            },
        };

    var result = new SigningService().Sign(new SignRequest
    {
        PdfPath = pdf,
        Cert = cert,
        Placements = placements,
        Reason = "Spike test",
        TsaUrl = tsa,
    });
    Console.WriteLine($"signed:  level={result.PadesLevel}  out={result.OutputPath}");

    var sigs = new SigningService().Verify(result.OutputPath);
    Console.WriteLine($"verify:  {sigs.Count} signature(s)");
    foreach (var s in sigs)
        Console.WriteLine($"   valid={s.Valid} signer={s.Signer} issuer={s.Issuer} level={s.Level} ts={s.HasTimestamp}\n   detail: {s.Detail}");

    var pass = sigs.Any(s => s.Valid);
    Console.WriteLine(pass ? "\nRESULT: PASS" : "\nRESULT: FAIL");
    Console.WriteLine($"open in Adobe to confirm: {result.OutputPath}");
    return pass ? 0 : 3;
}
