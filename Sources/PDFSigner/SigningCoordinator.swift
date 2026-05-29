import Foundation
import Security

struct SignRequest: @unchecked Sendable {
    var pdf: URL
    var cert: CertificateInfo
    var visible: Bool
    /// One or more placements (empty = invisible). >1 = single signature with
    /// multiple widget appearances (e.g. signed on every page).
    var placements: [PlacementSpec]
    var reason: String?
    var location: String?
    var signerName: String?
    var tsaURL: String?
}

struct SignaturePlacement {
    var page: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// A placement plus its pre-rendered appearance bitmap (straight-alpha RGBA8,
/// top row first).
struct PlacementSpec {
    var placement: SignaturePlacement
    var rgba: Data?
    var w: Int = 0
    var h: Int = 0
    /// Vector-text lines to render (used when `rgba` is nil). Empty => core
    /// composes a default "Firmado por: …" line itself.
    var lines: [String] = []
    /// Box-local X (points) where the text block starts (right of any logo).
    var textX: Double = 2
    /// Opaque images (logo/handwriting, QR) drawn alongside the vector text.
    var images: [PlacedImageSpec] = []
}

/// An opaque image to embed at a sub-rect of the signature box (Option B).
/// `rgba` is straight-alpha RGBA8, `pxW`×`pxH`; `x,y,w,h` are box-local points.
struct PlacedImageSpec {
    var rgba: Data
    var pxW: Int
    var pxH: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct SignResult: Sendable {
    var outputURL: URL
    var padesLevel: String
    var signerCN: String
}

/// Orchestrates the callback-signer round-trip: prepare → SecKey sign → finalize.
enum SigningCoordinator {
    static func sign(_ req: SignRequest) throws -> SignResult {
        if req.cert.isExpired { throw SigningError.certExpired }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfsigner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let client = CoreClient(workDir: workDir)

        var placements: [[String: Any]] = []
        if req.visible {
            for (i, spec) in req.placements.enumerated() {
                let p = spec.placement
                var dict: [String: Any] = [
                    "page": p.page, "x": p.x, "y": p.y, "w": p.w, "h": p.h,
                    "lines": spec.lines,
                    "text_x": spec.textX,
                ]
                if let rgba = spec.rgba, spec.w > 0, spec.h > 0 {
                    let imgPath = workDir.appendingPathComponent("appearance-\(i).rgba")
                    try rgba.write(to: imgPath)
                    dict["image"] = ["rgba_path": imgPath.path, "width": spec.w, "height": spec.h]
                }
                if !spec.images.isEmpty {
                    var imgs: [[String: Any]] = []
                    for (j, pim) in spec.images.enumerated() {
                        let imgPath = workDir.appendingPathComponent("placed-\(i)-\(j).rgba")
                        try pim.rgba.write(to: imgPath)
                        imgs.append([
                            "rgba_path": imgPath.path,
                            "width": pim.pxW, "height": pim.pxH,
                            "x": pim.x, "y": pim.y, "w": pim.w, "h": pim.h,
                        ])
                    }
                    dict["images"] = imgs
                }
                placements.append(dict)
            }
        }

        var prepareReq: [String: Any] = [
            "op": "prepare",
            "pdf": req.pdf.path,
            "cert_chain": req.cert.certChainDER.map { $0.base64EncodedString() },
            "placements": placements,
            "work_dir": workDir.path,
        ]
        if let r = req.reason { prepareReq["reason"] = r }
        if let l = req.location { prepareReq["location"] = l }
        if let n = req.signerName { prepareReq["name"] = n }
        if let t = req.tsaURL, !t.isEmpty { prepareReq["tsa_url"] = t }

        let prep = try client.request(prepareReq)
        if (prep["status"] as? String) == "error" {
            throw SigningError.coreFailed(
                code: prep["code"] as? String ?? "CORE_CRASH",
                message: prep["message"] as? String ?? "")
        }
        guard let handle = prep["handle"] as? String,
              let digestB64 = prep["digest"] as? String,
              let alg = prep["sig_alg"] as? String,
              let tbs = Data(base64Encoded: digestB64) else {
            throw SigningError.signFailed("respuesta de preparación inválida")
        }

        // Sign the SignedAttributes via the Keychain. Key never leaves.
        let identity = CallbackSigner.identity(of: req.cert)
        let signature = try CallbackSigner.sign(tbs: tbs, identity: identity, algorithm: alg)

        let fin = try client.request([
            "op": "finalize",
            "handle": handle,
            "signature": signature.base64EncodedString(),
        ])
        if (fin["status"] as? String) == "error" {
            throw SigningError.coreFailed(
                code: fin["code"] as? String ?? "CORE_CRASH",
                message: fin["message"] as? String ?? "")
        }
        guard let out = fin["out"] as? String else {
            throw SigningError.signFailed("respuesta de finalización inválida")
        }
        return SignResult(
            outputURL: URL(fileURLWithPath: out),
            padesLevel: fin["pades_level"] as? String ?? "B-B",
            signerCN: fin["signer_cn"] as? String ?? req.cert.commonName)
    }

    static func verify(_ pdf: URL) throws -> [VerificationDisplay] {
        let workDir = FileManager.default.temporaryDirectory
        let client = CoreClient(workDir: workDir)
        let resp = try client.request(["op": "verify", "pdf": pdf.path])
        if (resp["status"] as? String) == "error" {
            throw SigningError.coreFailed(
                code: resp["code"] as? String ?? "NO_SIGNATURE",
                message: resp["message"] as? String ?? "")
        }
        let sigs = resp["signatures"] as? [[String: Any]] ?? []
        return sigs.map(VerificationDisplay.init)
    }
}
