using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace PdfLocalCert.Core;

/// <summary>
/// Signs the core's to-be-signed bytes via CNG. The private key stays in the
/// Windows store. Ported from the Phase 3 spike (validated RSA + ECDSA on the VM).
///
/// CRITICAL CONTRACT (core/src/sign.rs:281): the protocol's `digest` field carries
/// the FULL SignedAttributes DER (the TBS message), NOT a pre-hashed digest. The
/// macOS shell signs it with *message* algorithms (hash-then-sign), so on Windows
/// we MUST use SignData (which hashes internally), never SignHash. SignHash would
/// treat the ~135 DER bytes as a SHA-256 digest and silently emit an invalid sig.
///
/// ECDSA: the core's CMS expects ecdsa-with-SHA256 as a DER SEQUENCE{r,s}. .NET's
/// default ECDSA output is raw P1363 (r‖s), so we request Rfc3279DerSequence.
/// </summary>
public static class CngSigner
{
    /// <summary>Sign <paramref name="tbs"/> with the cert's private key. <paramref name="sigAlg"/>
    /// comes straight from the prepare response ("rsa-pkcs1-sha256" | "ecdsa-sha256").</summary>
    public static byte[] Sign(X509Certificate2 cert, byte[] tbs, string sigAlg)
    {
        switch (sigAlg)
        {
            case "rsa-pkcs1-sha256":
                using (var rsa = cert.GetRSAPrivateKey()
                    ?? throw new SigningException("KEY_LOCKED", "certificate has no RSA private key"))
                {
                    return rsa.SignData(tbs, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

            case "ecdsa-sha256":
                using (var ec = cert.GetECDsaPrivateKey()
                    ?? throw new SigningException("KEY_LOCKED", "certificate has no ECDSA private key"))
                {
                    return ec.SignData(tbs, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
                }

            default:
                throw new SigningException("CORE_CRASH", $"unexpected sig_alg from core: {sigAlg}");
        }
    }

    /// <summary>Verify a signature against the cert's PUBLIC key, mirroring the exact
    /// algorithm/format we signed with. Independent of the core/Adobe — the core's
    /// verify is RSA-only, so this is our only crypto proof for ECDSA.</summary>
    public static bool SelfVerify(X509Certificate2 cert, byte[] tbs, byte[] sig, string sigAlg)
    {
        switch (sigAlg)
        {
            case "rsa-pkcs1-sha256":
                using (var rsa = cert.GetRSAPublicKey()
                    ?? throw new SigningException("CORE_CRASH", "certificate has no RSA public key"))
                {
                    return rsa.VerifyData(tbs, sig, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

            case "ecdsa-sha256":
                using (var ec = cert.GetECDsaPublicKey()
                    ?? throw new SigningException("CORE_CRASH", "certificate has no ECDSA public key"))
                {
                    return ec.VerifyData(tbs, sig, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
                }

            default:
                throw new SigningException("CORE_CRASH", $"unexpected sig_alg: {sigAlg}");
        }
    }
}
