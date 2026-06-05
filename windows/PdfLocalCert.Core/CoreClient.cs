using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace PdfLocalCert.Core;

/// <summary>
/// Talks to the bundled <c>pdflocalcert-core.exe</c> sidecar over the line-delimited
/// JSON protocol — one request line in, one response line out, per spawn. Ported from
/// the macOS CoreClient (apple/Sources/PDFLocalCert/CoreClient.swift) and the Phase 3
/// spike, which proved this exact mechanism on Windows.
///
/// The private key never reaches the core: <c>prepare</c> returns the to-be-signed
/// bytes, the shell signs them via CNG, and <c>finalize</c> assembles the CMS.
/// </summary>
public sealed class CoreClient
{
    private readonly string _exePath;

    /// <summary>
    /// Per-sign working directory. The core's <c>finalize</c> recovers <c>prepare</c>'s
    /// state file from <c>$PDFLOCALCERT_WORK</c> (core/src/sign.rs:load_state), so it is
    /// set on every spawn. Required between a prepare and its finalize.
    /// </summary>
    public string? WorkDir { get; set; }

    public CoreClient(string? exePath = null)
        => _exePath = exePath ?? ResolveExePath();

    /// <summary>The bundled exe (next to the app) first, then the dev cross-compile output.</summary>
    public static string ResolveExePath()
    {
        // Packaged layout: the exe ships beside the app executable.
        var beside = Path.Combine(AppContext.BaseDirectory, "pdflocalcert-core.exe");
        if (File.Exists(beside)) return beside;

        // Dev layout: <repo>/core/target/x86_64-pc-windows-msvc/release/. Walk up from
        // the running assembly to find the repo root.
        var dir = AppContext.BaseDirectory;
        for (var i = 0; i < 10 && dir != null; i++)
        {
            var candidate = Path.Combine(dir,
                "core", "target", "x86_64-pc-windows-msvc", "release", "pdflocalcert-core.exe");
            if (File.Exists(candidate)) return candidate;
            dir = Directory.GetParent(dir)?.FullName;
        }
        throw new FileNotFoundException(
            "pdflocalcert-core.exe not found beside the app or in the dev build output.");
    }

    /// <summary>Send one request, parse the one-line JSON response.</summary>
    public JsonElement Request(object req)
    {
        var psi = new ProcessStartInfo(_exePath)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = new UTF8Encoding(false),
        };
        if (WorkDir != null) psi.Environment["PDFLOCALCERT_WORK"] = WorkDir;

        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException("failed to spawn pdflocalcert-core");

        var line = JsonSerializer.Serialize(req);
        p.StandardInput.Write(line);
        p.StandardInput.Write('\n');
        p.StandardInput.Flush();
        p.StandardInput.Close();

        var stdout = p.StandardOutput.ReadToEnd();
        var stderr = p.StandardError.ReadToEnd();
        p.WaitForExit();

        var first = stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()
            ?? throw new InvalidOperationException($"core returned no response. stderr: {stderr}");
        return JsonDocument.Parse(first).RootElement.Clone();
    }

    public bool Ping()
    {
        var resp = Request(new Dictionary<string, object> { ["op"] = "ping" });
        return resp.TryGetProperty("pong", out var pong) && pong.GetBoolean();
    }
}
