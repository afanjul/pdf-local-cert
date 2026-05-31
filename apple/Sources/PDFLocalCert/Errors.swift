import Foundation

/// User-facing signing errors. Codes mirror the core's error taxonomy.
enum SigningError: LocalizedError {
    case noDocument
    case noCertificate
    case certExpired
    case keyLocked
    case coreFailed(code: String, message: String)
    case signFailed(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .noDocument: return NSLocalizedString("error_no_document", comment: "")
        case .noCertificate: return NSLocalizedString("error_no_certificate", comment: "")
        case .certExpired: return NSLocalizedString("error_cert_expired", comment: "")
        case .keyLocked: return NSLocalizedString("error_key_locked", comment: "")
        case let .coreFailed(code, message): return "\(localized(code)) (\(code): \(message))"
        case let .signFailed(m): return String(format: NSLocalizedString("error_sign_failed", comment: ""), m)
        case let .io(m): return String(format: NSLocalizedString("error_io", comment: ""), m)
        }
    }

    private func localized(_ code: String) -> String {
        switch code {
        case "BAD_PDF": return NSLocalizedString("error_bad_pdf", comment: "")
        case "PDF_ENCRYPTED": return NSLocalizedString("error_pdf_encrypted", comment: "")
        case "TSA_TIMEOUT": return NSLocalizedString("error_tsa_timeout", comment: "")
        case "CMS_TOO_BIG": return NSLocalizedString("error_cms_too_big", comment: "")
        default: return NSLocalizedString("error_internal", comment: "")
        }
    }
}
