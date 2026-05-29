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
        case .noDocument: return "Arrastra un PDF para empezar."
        case .noCertificate: return "Selecciona un certificado de firma."
        case .certExpired: return "El certificado ha caducado."
        case .keyLocked: return "PIN incorrecto o tarjeta bloqueada."
        case let .coreFailed(code, message): return "\(localized(code)) (\(code): \(message))"
        case let .signFailed(m): return "No se pudo firmar: \(m)"
        case let .io(m): return "Error de archivo: \(m)"
        }
    }

    private func localized(_ code: String) -> String {
        switch code {
        case "BAD_PDF": return "El PDF no se pudo procesar."
        case "PDF_ENCRYPTED": return "El PDF está protegido."
        case "TSA_TIMEOUT": return "No se pudo obtener el sello de tiempo."
        case "CMS_TOO_BIG": return "La firma excede el espacio reservado."
        default: return "Error interno de firma."
        }
    }
}
