## ADDED Requirements

### Requirement: Enumerate signing identities from the Windows certificate store
The Windows shell SHALL enumerate certificates that have an associated private key from the current user's "My" certificate store (and the local-machine store where accessible), and present them as selectable signing identities showing common name, issuer, and expiry.

#### Scenario: Store contains signing certificates
- **WHEN** the user opens the certificate picker and the Windows store holds certificates with private keys
- **THEN** each such identity is listed with its common name, issuer, and not-after date

#### Scenario: Expired or non-signing certificates are marked
- **WHEN** a listed certificate is expired or its KeyUsage forbids digital signature / non-repudiation
- **THEN** the identity is flagged as not usable for signing (mirroring the macOS `canSign`/`isExpired` behavior)

#### Scenario: Duplicate certificates are de-duplicated
- **WHEN** the same certificate appears in more than one store location
- **THEN** it is shown only once, de-duplicated by certificate bytes

### Requirement: Sign the SignedAttributes digest via CNG without exporting the key
The Windows shell SHALL sign the digest returned by the core's `prepare` step using the selected certificate's CNG private key (`RSACng`/`ECDsaCng`), selecting the algorithm from the core's `sig_alg` field, and the private key SHALL never leave the certificate store.

#### Scenario: RSA PKCS#1 v1.5 SHA-256 signing
- **WHEN** the core returns `sig_alg` = `rsa-pkcs1-sha256` and a digest
- **THEN** the shell produces an RSA PKCS#1 v1.5 SHA-256 signature over that digest using the CNG key, and returns it to the core's `finalize`

#### Scenario: ECDSA P-256 SHA-256 signing
- **WHEN** the core returns `sig_alg` = `ecdsa-sha256` and a digest
- **THEN** the shell produces an ECDSA SHA-256 signature and encodes it as the DER `SEQUENCE` the core's CMS assembly expects

#### Scenario: Key is non-exportable / locked
- **WHEN** the private key cannot be accessed (e.g. non-exportable, PIN cancelled)
- **THEN** signing fails with a clear error and no key material is exported or logged

### Requirement: Build the full certificate chain for embedding
The Windows shell SHALL assemble the signer certificate chain (leaf first, then intermediates, then root when available) for the core to embed in the CMS, using `X509Chain` and a normalized-DN manual walk so reissued intermediates (e.g. FNMT/UANATACA) are still linked.

#### Scenario: Trust engine links the full chain
- **WHEN** `X509Chain` resolves the signer to its intermediates and root
- **THEN** the resolved chain (leaf-first DER list) is passed to the core's `prepare`

#### Scenario: Trust engine stops at the leaf
- **WHEN** the OS trust engine returns only the leaf because an intermediate's authority key identifier no longer matches
- **THEN** the shell falls back to matching each cert's normalized issuer DN against candidate subjects and uses whichever chain is longer

### Requirement: License token stored without the macOS Keychain
The Windows shell SHALL persist the license token using a Windows-native protected store (DPAPI CurrentUser or registry) rather than the macOS Keychain, preserving the free/pro tier behavior.

#### Scenario: Token persists across launches
- **WHEN** a user activates a license and restarts the app
- **THEN** the stored token is read back and the pro tier is restored without re-entry
