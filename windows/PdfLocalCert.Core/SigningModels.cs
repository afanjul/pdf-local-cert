using System.Security.Cryptography.X509Certificates;

namespace PdfLocalCert.Core;

/// <summary>A signing identity discovered in the Windows certificate store.</summary>
/// <remarks>Mirrors macOS CertificateInfo. Holds the X509Certificate2 so the signer
/// can reach its private key via CNG; the key itself never leaves the store.
/// Init-only (not `required`) so the WinUI XAML type provider can activate it.</remarks>
public sealed class CertificateInfo
{
    public string CommonName { get; init; } = "";
    public string Issuer { get; init; } = "";
    public DateTime NotAfter { get; init; }
    public bool CanSign { get; init; }
    public string Thumbprint { get; init; } = "";
    /// <summary>"RSA" | "ECDSA" | other OID friendly name.</summary>
    public string KeyAlgorithm { get; init; } = "";
    public X509Certificate2 Certificate { get; init; } = null!;

    public bool IsExpired => NotAfter < DateTime.Now;
}

/// <summary>One visible-signature placement, in PDF user space (origin bottom-left, points).</summary>
public sealed class PlacementSpec
{
    public int Page { get; init; }
    public double X { get; init; }
    public double Y { get; init; }
    public double W { get; init; }
    public double H { get; init; }
    public IReadOnlyList<string> Lines { get; init; } = Array.Empty<string>();
    public bool Border { get; init; }
    public bool Background { get; init; }
}

/// <summary>A request to sign a PDF. Mirrors macOS SignRequest.</summary>
public sealed class SignRequest
{
    public required string PdfPath { get; init; }
    public required CertificateInfo Cert { get; init; }
    /// <summary>Empty = invisible signature.</summary>
    public IReadOnlyList<PlacementSpec> Placements { get; init; } = Array.Empty<PlacementSpec>();
    public string? Reason { get; init; }
    public string? Location { get; init; }
    public string? SignerName { get; init; }
    /// <summary>RFC 3161 TSA URL. Null/empty = B-B only.</summary>
    public string? TsaUrl { get; init; }
}

/// <summary>Result of a successful sign.</summary>
public sealed class SignResult
{
    public required string OutputPath { get; init; }
    public required string PadesLevel { get; init; } // "B-B" | "B-T"
    public required string SignerCommonName { get; init; }
}

/// <summary>One verified signature, surfaced to the UI. Mirrors macOS VerificationDisplay.</summary>
public sealed class VerificationResult
{
    public required bool Valid { get; init; }
    public required string Signer { get; init; }
    public required string Issuer { get; init; }
    public required string Level { get; init; }
    public required bool HasTimestamp { get; init; }
    public required string Detail { get; init; }
}

/// <summary>User-facing signing error. Codes mirror the core's taxonomy (Errors.swift).</summary>
public sealed class SigningException : Exception
{
    public string Code { get; }
    public SigningException(string code, string message) : base(message) => Code = code;
}
