using System.Security.Cryptography.X509Certificates;

namespace BureaucratPdf.Core;

/// <summary>
/// Enumerates signing identities from the Windows certificate store and assembles
/// cert chains. Ports IdentityStore.swift (loadIdentities / chainDER / buildChainByDN)
/// and the Phase 3 spike, both validated on the Win11 VM.
/// </summary>
public static class IdentityStore
{
    /// <summary>All certs in CurrentUser\My that hold a private key and permit signing,
    /// most-recent-expiry first (mirrors the macOS picker order).</summary>
    public static List<CertificateInfo> LoadSigningIdentities()
    {
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);

        var result = new List<CertificateInfo>();
        foreach (var c in store.Certificates)
        {
            if (!c.HasPrivateKey) continue;
            result.Add(new CertificateInfo
            {
                CommonName = Dn.Cn(c.Subject),
                Issuer = Dn.Cn(c.Issuer),
                NotAfter = c.NotAfter,
                CanSign = KeyUsageAllowsSigning(c),
                Thumbprint = c.Thumbprint,
                KeyAlgorithm = KeyAlgorithm(c),
                Certificate = c,
            });
        }
        result.Sort((a, b) => b.NotAfter.CompareTo(a.NotAfter));
        return result;
    }

    /// <summary>Leaf-first DER list (signer, intermediates, root if present), embedded in
    /// the CMS so verifiers can build a trust path from the signature alone. Tries X509Chain
    /// first, then a manual issuer→subject DN walk, keeping whichever is longer — mirrors
    /// IdentityStore.chainDER, which exists because FNMT/UANATACA reissued intermediates
    /// break automatic AKI linkage.</summary>
    public static List<byte[]> BuildChain(X509Certificate2 leaf)
    {
        var viaChain = new List<X509Certificate2>();
        using (var chain = new X509Chain())
        {
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllFlags; // populate even if untrusted
            chain.Build(leaf);
            foreach (var el in chain.ChainElements) viaChain.Add(el.Certificate);
        }

        var viaDn = WalkByDn(leaf);
        var best = viaDn.Count >= viaChain.Count ? viaDn : viaChain;
        if (best.Count == 0) best = new List<X509Certificate2> { leaf };
        return best.Select(c => c.RawData).ToList();
    }

    /// <summary>Walk leaf → issuer by matching DER-encoded DNs against candidate stores,
    /// stopping at a self-signed root or a dead end. Mirrors buildChainByDN.</summary>
    private static List<X509Certificate2> WalkByDn(X509Certificate2 leaf)
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

    private static List<X509Certificate2> CandidatePool()
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

    /// <summary>True if KeyUsage permits digitalSignature or nonRepudiation, or is absent.
    /// Mirrors keyUsageAllowsSigning.</summary>
    private static bool KeyUsageAllowsSigning(X509Certificate2 cert)
    {
        foreach (var ext in cert.Extensions)
        {
            if (ext is X509KeyUsageExtension ku)
            {
                const X509KeyUsageFlags allowed =
                    X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation;
                return (ku.KeyUsages & allowed) != 0;
            }
        }
        return true;
    }

    private static string KeyAlgorithm(X509Certificate2 c)
        => c.GetECDsaPublicKey() != null ? "ECDSA"
         : c.GetRSAPublicKey() != null ? "RSA"
         : c.PublicKey.Oid.FriendlyName ?? c.PublicKey.Oid.Value ?? "?";
}

/// <summary>Pull the CN out of an RFC 2253 distinguished name.</summary>
public static class Dn
{
    public static string Cn(string distinguishedName)
    {
        foreach (var part in distinguishedName.Split(','))
        {
            var t = part.Trim();
            if (t.StartsWith("CN=", StringComparison.OrdinalIgnoreCase)) return t[3..];
        }
        return distinguishedName;
    }
}
