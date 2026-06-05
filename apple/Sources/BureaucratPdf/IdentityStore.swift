import Foundation
import Security

/// A signing identity discovered in the Keychain.
struct CertificateInfo: Identifiable, Hashable, @unchecked Sendable {
    let id = UUID()
    let commonName: String
    let issuer: String
    let notAfter: Date?
    let isExpired: Bool
    let canSign: Bool
    let certDER: Data
    /// Signer cert first, then intermediates (and root if available).
    let certChainDER: [Data]
    fileprivate let identity: SecIdentity

    static func == (l: CertificateInfo, r: CertificateInfo) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Enumerates Keychain identities usable for signing.
enum IdentityStore {
    static func loadIdentities() -> [CertificateInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [SecIdentity] else {
            return []
        }
        // The same identity often lives in more than one keychain (e.g. System +
        // iCloud "Local Items"), so SecItemCopyMatching returns it once per
        // keychain. Dedup by certificate DER so the picker shows each cert once.
        var seen = Set<Data>()
        return items.compactMap(info(for:))
            .filter { seen.insert($0.certDER).inserted }
            .sorted { ($0.notAfter ?? .distantPast) > ($1.notAfter ?? .distantPast) }
    }

    private static func info(for identity: SecIdentity) -> CertificateInfo? {
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let cert = certRef else { return nil }

        let der = SecCertificateCopyData(cert) as Data
        let cn = (try? commonName(of: cert)) ?? "(sin nombre)"
        let issuer = issuerName(of: cert)
        let notAfter = expiry(of: cert)
        let expired = notAfter.map { $0 < Date() } ?? false
        let canSign = keyUsageAllowsSigning(cert)

        return CertificateInfo(
            commonName: cn,
            issuer: issuer,
            notAfter: notAfter,
            isExpired: expired,
            canSign: canSign,
            certDER: der,
            certChainDER: chainDER(for: cert),
            identity: identity
        )
    }

    /// Build the certificate chain (leaf first, then intermediates, then root) so
    /// verifiers (Adobe) can construct a trust path from the CMS alone.
    ///
    /// `SecTrust` is tried first, but for FNMT / UANATACA certs it routinely stops
    /// at the leaf — the issuing intermediates have been reissued and their
    /// AuthorityKeyIdentifier no longer matches the keychain copies, so SecTrust
    /// won't link them. We therefore also walk the chain manually by matching each
    /// cert's normalized issuer DN to a candidate's subject DN, and keep whichever
    /// path is longer. Without the intermediates embedded, Adobe shows
    /// "An error occurred / Signer's identity has not yet been verified" for
    /// representante (AC Representación) signatures.
    private static func chainDER(for cert: SecCertificate) -> [Data] {
        let leaf = SecCertificateCopyData(cert) as Data

        var trustChain: [SecCertificate] = []
        var trust: SecTrust?
        if SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
           let trust {
            _ = SecTrustEvaluateWithError(trust, nil) // populates chain even if untrusted
            trustChain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        }

        let manual = buildChainByDN(cert)
        let best = manual.count >= trustChain.count ? manual : trustChain
        guard !best.isEmpty else { return [leaf] }
        return best.map { SecCertificateCopyData($0) as Data }
    }

    /// Walk leaf → issuer by matching normalized DNs against all keychain certs,
    /// stopping at a self-signed root (issuer == subject) or when no issuer is found.
    private static func buildChainByDN(_ leaf: SecCertificate) -> [SecCertificate] {
        let pool = allKeychainCerts()
        var chain = [leaf]
        var seen: Set<Data> = [SecCertificateCopyData(leaf) as Data]
        var current = leaf
        while chain.count < 10 {
            guard let issuer = SecCertificateCopyNormalizedIssuerSequence(current) as Data?,
                  let subject = SecCertificateCopyNormalizedSubjectSequence(current) as Data?,
                  issuer != subject else { break } // self-signed root reached
            guard let next = pool.first(where: {
                (SecCertificateCopyNormalizedSubjectSequence($0) as Data?) == issuer
                    && !seen.contains(SecCertificateCopyData($0) as Data)
            }) else { break }
            chain.append(next)
            seen.insert(SecCertificateCopyData(next) as Data)
            current = next
        }
        return chain
    }

    /// All certificates visible in the user's keychains (candidate intermediates).
    private static func allKeychainCerts() -> [SecCertificate] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
              let certs = r as? [SecCertificate] else { return [] }
        return certs
    }

    private static func commonName(of cert: SecCertificate) throws -> String {
        var cn: CFString?
        let status = SecCertificateCopyCommonName(cert, &cn)
        guard status == errSecSuccess, let cn else { throw SigningError.noCertificate }
        return cn as String
    }

    private static func issuerName(of cert: SecCertificate) -> String {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1IssuerName] as CFArray, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
              let list = entry[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return "(emisor desconocido)"
        }
        for item in list {
            if let label = item[kSecPropertyKeyLabel as String] as? String,
               label == "2.5.4.3", // commonName
               let value = item[kSecPropertyKeyValue as String] as? String {
                return value
            }
        }
        // fall back to organization
        for item in list {
            if let value = item[kSecPropertyKeyValue as String] as? String { return value }
        }
        return "(emisor desconocido)"
    }

    private static func expiry(of cert: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let raw = entry[kSecPropertyKeyValue as String] as? Double else {
            return nil
        }
        // Value is seconds since the reference date used by CSSM (2001 epoch).
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    /// True if KeyUsage permits digitalSignature or nonRepudiation, or if absent.
    private static func keyUsageAllowsSigning(_ cert: SecCertificate) -> Bool {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDKeyUsage] as CFArray, nil) as? [String: Any],
              let entry = values[kSecOIDKeyUsage as String] as? [String: Any],
              let raw = entry[kSecPropertyKeyValue as String] as? NSNumber else {
            return true // no KeyUsage extension: allow
        }
        let usage = raw.intValue
        let digitalSignature = 1 << 0
        let nonRepudiation = 1 << 1
        return (usage & (digitalSignature | nonRepudiation)) != 0
    }
}

/// Signs a digest with the private key behind a Keychain identity.
/// The key never leaves the Keychain/secure element.
enum CallbackSigner {
    static func sign(tbs: Data, identity: SecIdentity, algorithm: String) throws -> Data {
        var keyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess, let key = keyRef else {
            throw SigningError.keyLocked
        }
        let secAlg: SecKeyAlgorithm
        switch algorithm {
        case "ecdsa-sha256": secAlg = .ecdsaSignatureMessageX962SHA256
        default: secAlg = .rsaSignatureMessagePKCS1v15SHA256
        }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, secAlg, tbs as CFData, &error) else {
            let msg = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "firma fallida"
            throw SigningError.signFailed(msg)
        }
        return sig as Data
    }

    /// Resolve the SecIdentity for a CertificateInfo (held internally).
    static func identity(of info: CertificateInfo) -> SecIdentity { info.identity }
}
