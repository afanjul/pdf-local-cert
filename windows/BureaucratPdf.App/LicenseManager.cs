using System.Security.Cryptography;
using System.Text;
using Windows.Storage;

namespace BureaucratPdf.App;

/// <summary>
/// License + free-tier metering for Windows. Ports macOS LicenseManager, swapping
/// the Keychain for DPAPI (ProtectedData, CurrentUser) to store the token and
/// ApplicationData.LocalSettings for the monthly counter.
///
/// Pro is unlocked by a valid offline license token. The token issuance/Stripe
/// flow lives server-side (not bundled); Validate is the single seam to plug it in.
/// </summary>
public sealed class LicenseManager
{
    public enum Tier { Free, Pro }

    public Tier CurrentTier { get; private set; } = Tier.Free;
    public int MonthlyCount { get; private set; }

    /// <summary>Free tier: signatures per calendar month.</summary>
    public const int FreeMonthlyLimit = 10;

    public bool IsPro => CurrentTier == Tier.Pro;
    public int RemainingFreeSigns => Math.Max(0, FreeMonthlyLimit - MonthlyCount);

    private const string TokenSetting = "license.token";       // DPAPI-protected, base64
    private static ApplicationDataContainer Local => ApplicationData.Current.LocalSettings;

    public LicenseManager()
    {
        var token = ReadToken();
        if (token is not null && Validate(token)) CurrentTier = Tier.Pro;
        MonthlyCount = Local.Values[CountKey()] is int n ? n : 0;
    }

    /// <summary>
    /// Offline token check. A real deployment verifies a signed token against an
    /// embedded public key + expiry/grace; here we accept the documented format
    /// PDFS-XXXX-XXXX-XXXX so the gating/UI is exercised end-to-end.
    /// </summary>
    public static bool Validate(string key)
    {
        var parts = key.ToUpperInvariant().Split('-');
        return parts.Length == 4 && parts[0] == "PDFS" && parts.Skip(1).All(p => p.Length == 4);
    }

    public bool Activate(string key)
    {
        if (!Validate(key)) return false;
        WriteToken(key);
        CurrentTier = Tier.Pro;
        return true;
    }

    public void Deactivate()
    {
        Local.Values.Remove(TokenSetting);
        CurrentTier = Tier.Free;
    }

    /// <summary>Record one successful signature against the monthly free quota.</summary>
    public void RecordSign()
    {
        if (IsPro) return;
        MonthlyCount++;
        Local.Values[CountKey()] = MonthlyCount;
    }

    // ── DPAPI token storage (CurrentUser scope) ──────────────────────────────

    private static void WriteToken(string key)
    {
        var plain = Encoding.UTF8.GetBytes(key);
        var enc = ProtectedData.Protect(plain, optionalEntropy: null, DataProtectionScope.CurrentUser);
        Local.Values[TokenSetting] = Convert.ToBase64String(enc);
    }

    private static string? ReadToken()
    {
        if (Local.Values[TokenSetting] is not string b64) return null;
        try
        {
            var enc = Convert.FromBase64String(b64);
            var plain = ProtectedData.Unprotect(enc, optionalEntropy: null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            return null; // tampered / different user — treat as no license
        }
    }

    private static string CountKey()
    {
        var now = DateTime.Now;
        return $"signCount-{now.Year}-{now.Month}";
    }
}
