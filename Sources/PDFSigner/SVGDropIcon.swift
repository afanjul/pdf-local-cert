import SwiftUI
import WebKit

/// Animated drop-zone icon (fountain pen signing a PDF) rendered via WebKit so
/// the SVG's CSS keyframe animations run natively. The SVG is inlined as a
/// string rather than a bundled resource: SPM resource bundles are not copied
/// into the hand-assembled `.app` by `scripts/build.sh`, so `Bundle.module`
/// would fail on a clean (notarized) machine. Inlining keeps it portable.
struct SVGDropIcon: NSViewRepresentable {
    var isActive: Bool

    private static let pageHTML: String = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    *{margin:0;padding:0;}
    html,body{width:100%;height:100%;overflow:hidden;background:transparent;}
    svg{width:100%;height:100%;}
    </style></head><body>\(svg)</body></html>
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = PassthroughWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground") // transparent
        // The icon must not steal file drops. A WKWebView registers itself as a
        // drag destination — but on *internal subviews*, asynchronously, only
        // once the web content has finished loading. That is why earlier
        // attempts (unregistering just the outer view) failed: dropping "on the
        // pen" was swallowed by an inner subview. The navigation delegate strips
        // dragged types from the whole subtree on didFinish; see Coordinator.
        wv.navigationDelegate = context.coordinator
        wv.loadHTMLString(Self.pageHTML, baseURL: nil)
        return wv
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.disableDragAndDropRecursively()
        }
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let action = isActive ? "add" : "remove"
        wv.evaluateJavaScript(
            "var e=document.querySelector('svg');if(e)e.classList.\(action)('drag-active')",
            completionHandler: nil
        )
    }

    // MARK: - Inlined asset

    private static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 220" preserveAspectRatio="xMidYMid meet" role="img" aria-labelledby="ttl dsc">
      <title id="ttl">Subir documento para firmar</title>
      <desc id="dsc">Documento PDF con esquina doblada junto a una estilográfica apoyada en un tintero. Al arrastrar un archivo, la pluma sale del tintero y su punta recorre el documento firmándolo con una rúbrica cursiva en tiempo real.</desc>

      <defs>
        <linearGradient id="paperGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#ffffff"/>
          <stop offset="1" stop-color="#f6f2e9"/>
        </linearGradient>
        <linearGradient id="foldGrad" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#efe9da"/>
          <stop offset="1" stop-color="#ddd4c0"/>
        </linearGradient>
        <linearGradient id="glassGrad" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stop-color="#eef5f7"/>
          <stop offset="0.5" stop-color="#dde7eb"/>
          <stop offset="1" stop-color="#c6d3d9"/>
        </linearGradient>
        <linearGradient id="inkGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#2a3560"/>
          <stop offset="1" stop-color="#131a33"/>
        </linearGradient>
        <linearGradient id="barrelGrad" x1="0" y1="0.5" x2="1" y2="0.5">
          <stop offset="0" stop-color="#0e131d"/>
          <stop offset="0.5" stop-color="#3f4f6a"/>
          <stop offset="1" stop-color="#0c111a"/>
        </linearGradient>
        <linearGradient id="sectionGrad" x1="0" y1="0.5" x2="1" y2="0.5">
          <stop offset="0" stop-color="#090c11"/>
          <stop offset="0.5" stop-color="#242b38"/>
          <stop offset="1" stop-color="#080b0f"/>
        </linearGradient>
        <linearGradient id="bandGrad" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stop-color="#f6dd8e"/>
          <stop offset="0.5" stop-color="#d7aa50"/>
          <stop offset="1" stop-color="#b3853a"/>
        </linearGradient>
        <linearGradient id="nibGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#f8e4a4"/>
          <stop offset="1" stop-color="#c69737"/>
        </linearGradient>

        <filter id="softShadow" x="-40%" y="-40%" width="180%" height="190%">
          <feDropShadow dx="0" dy="2.6" stdDeviation="3" flood-color="#1b203a" flood-opacity="0.18"/>
        </filter>
        <filter id="penShadow" x="-60%" y="-30%" width="220%" height="160%">
          <feDropShadow dx="1.2" dy="2" stdDeviation="1.6" flood-color="#0b1020" flood-opacity="0.30"/>
        </filter>

        <style>
          .doc-wrap{
            transform-box:fill-box; transform-origin:center;
            animation:breathe 5s ease-in-out infinite;
          }
          .pen{
            transform-box:view-box; transform-origin:0 0;
            transform:translate(161px,173px) rotate(-30deg);
            animation:penIdle 4.2s ease-in-out infinite;
          }
          .signature{
            fill:none; stroke:#1d2a52; stroke-width:1.7;
            stroke-linecap:round; stroke-linejoin:round;
            stroke-dasharray:100; stroke-dashoffset:100; opacity:0;
          }
          .blot{ transform-box:fill-box; transform-origin:center; opacity:0; }

          .drag-active .pen{ animation:penSign 7s ease-in-out infinite; }
          .drag-active .signature{ animation:sign 7s linear infinite; }
          .drag-active .blot{ animation:blot 7s ease-in-out infinite; }

          @keyframes breathe{
            0%,100%{ transform:scale(1); }
            50%{ transform:scale(1.015); }
          }
          @keyframes penIdle{
            0%,100%{ transform:translate(161px,173px) rotate(-30deg); }
            50%{ transform:translate(160px,169px) rotate(-31deg); }
          }

          /* nib (local 0,0) follows the exact signature path while it is drawn */
          @keyframes penSign{
            0%  { transform:translate(161px,173px) rotate(-30deg); animation-timing-function:cubic-bezier(.34,1.56,.64,1); }
            6%  { transform:translate(161px,158px) rotate(-33deg); }
            11% { transform:translate(161px,162px) rotate(-31deg); }
            20% { transform:translate(97px,141px)  rotate(-24deg); }
            23% { transform:translate(96px,138px)  rotate(-24deg); }
            25% { transform:translate(97px,127px)  rotate(-21deg); }
            27% { transform:translate(101px,132px) rotate(-23deg); }
            29% { transform:translate(101px,138px) rotate(-21deg); }
            31% { transform:translate(103px,138px) rotate(-22deg); }
            33% { transform:translate(108px,134px) rotate(-20deg); }
            35% { transform:translate(111px,138px) rotate(-22deg); }
            37% { transform:translate(114px,136px) rotate(-20deg); }
            39% { transform:translate(117px,136px) rotate(-21deg); }
            41% { transform:translate(120px,136px) rotate(-20deg); }
            43% { transform:translate(124px,136px) rotate(-22deg); }
            45% { transform:translate(128px,135px) rotate(-20deg); }
            47% { transform:translate(131px,134px) rotate(-21deg); }
            49% { transform:translate(133px,139px) rotate(-22deg); }
            51% { transform:translate(126px,143px) rotate(-23deg); }
            53% { transform:translate(111px,143px) rotate(-25deg); }
            55% { transform:translate(99px,140px)  rotate(-24deg); }
            62% { transform:translate(112px,128px) rotate(-27deg); }
            72% { transform:translate(159px,160px) rotate(-29deg); }
            78% { transform:translate(161px,173px) rotate(-30deg); }
            100%{ transform:translate(161px,173px) rotate(-30deg); }
          }
          @keyframes sign{
            0%,22%{ stroke-dashoffset:100; opacity:0; }
            23%   { stroke-dashoffset:100; opacity:1; }
            55%   { stroke-dashoffset:0; opacity:1; }
            82%   { stroke-dashoffset:0; opacity:1; }
            90%   { stroke-dashoffset:0; opacity:0; }
            100%  { stroke-dashoffset:0; opacity:0; }
          }
          @keyframes blot{
            0%,21%{ opacity:0; transform:scale(0); }
            23%   { opacity:.85; transform:scale(1.15); }
            27%   { opacity:.5; transform:scale(1); }
            82%   { opacity:.45; transform:scale(1); }
            90%   { opacity:0; transform:scale(1); }
            100%  { opacity:0; transform:scale(1); }
          }

          @media (prefers-reduced-motion:reduce){
            .doc-wrap,.pen,.signature,.blot{ animation:none !important; }
            .pen{ transform:translate(161px,173px) rotate(-30deg); }
            .signature{ opacity:0; }
            .blot{ opacity:0; }
          }
        </style>
      </defs>

      <ellipse cx="161" cy="208" rx="27" ry="4.5" fill="#1b203a" opacity="0.12"/>

      <!-- DOCUMENT -->
      <g class="doc-wrap">
        <path filter="url(#softShadow)" fill="url(#paperGrad)" stroke="#e6e0d2" stroke-width="0.8"
              d="M40,30 Q40,24 46,24 H122 L138,40 V146 Q138,152 132,152 H46 Q40,152 40,146 Z"/>
        <path fill="url(#foldGrad)" stroke="#d6cdba" stroke-width="0.6" d="M122,24 L138,40 L122,40 Z"/>
        <path fill="#000" opacity="0.05" d="M122,24 L138,40 L124,40 Z"/>

        <g>
          <rect x="52" y="39" width="44" height="3.6" rx="1.8" fill="#cfc7b5"/>
          <rect x="52" y="50" width="72" height="2.4" rx="1.2" fill="#ddd7c9"/>
          <rect x="52" y="58" width="72" height="2.4" rx="1.2" fill="#ddd7c9"/>
          <rect x="52" y="66" width="62" height="2.4" rx="1.2" fill="#ddd7c9"/>
          <rect x="52" y="74" width="72" height="2.4" rx="1.2" fill="#ddd7c9"/>
          <rect x="52" y="82" width="56" height="2.4" rx="1.2" fill="#ddd7c9"/>
          <rect x="52" y="90" width="72" height="2.4" rx="1.2" fill="#ddd7c9"/>
          <rect x="52" y="98" width="66" height="2.4" rx="1.2" fill="#ddd7c9"/>
          <rect x="52" y="106" width="48" height="2.4" rx="1.2" fill="#ddd7c9"/>
        </g>

        <g>
          <rect x="50" y="131" width="28" height="13" rx="3" fill="#b8434a"/>
          <text x="64" y="140.5" font-family="Helvetica, Arial, sans-serif" font-size="7.6"
                font-weight="700" letter-spacing="0.5" text-anchor="middle" fill="#ffffff">PDF</text>
        </g>
      </g>

      <!-- INK BLOT + SIGNATURE -->
      <g class="blot">
        <circle cx="96" cy="138" r="2.3" fill="#1d2a52"/>
        <circle cx="99" cy="135.5" r="1" fill="#1d2a52"/>
      </g>
      <path class="signature" pathLength="100"
            d="M96,138 C93,127 100,122 101,132 C101.5,137 99,142 103,138 C107,133 109,133 111,138 C113,141 115,130 117,136 C119,141 121,131 124,136 C127,140 129,130 131,134 C135,136 134,143 126,143 C116,143 106,143 99,140"/>

      <!-- INKWELL -->
      <g>
        <rect x="138" y="170" width="46" height="38" rx="7" fill="url(#glassGrad)" fill-opacity="0.55" stroke="#b6c4cb" stroke-width="0.8"/>
        <clipPath id="jarClip"><rect x="138.5" y="170.5" width="45" height="37" rx="6.5"/></clipPath>
        <g clip-path="url(#jarClip)">
          <rect x="138" y="176" width="46" height="32" fill="url(#inkGrad)"/>
          <ellipse cx="161" cy="176" rx="20" ry="4.4" fill="#34416f"/>
          <ellipse cx="161" cy="176" rx="13" ry="2.6" fill="#1a2347"/>
        </g>
        <ellipse cx="161" cy="171.5" rx="20" ry="4.6" fill="none" stroke="#aebbc2" stroke-width="0.8" opacity="0.8"/>
        <rect x="144" y="180" width="3" height="20" rx="1.5" fill="#ffffff" opacity="0.32"/>
      </g>

      <!-- FOUNTAIN PEN (nib at local 0,0) -->
      <g class="pen">
        <g filter="url(#penShadow)">
          <rect x="-3.9" y="-58" width="7.8" height="31" rx="3.9" fill="url(#barrelGrad)"/>
          <rect x="-2.9" y="-55" width="1.6" height="24" rx="0.8" fill="#ffffff" opacity="0.20"/>
          <circle cx="0" cy="-57" r="1.5" fill="url(#bandGrad)"/>
          <rect x="-3.9" y="-53" width="7.8" height="2" rx="1" fill="url(#bandGrad)" opacity="0.9"/>
          <rect x="2.6" y="-50" width="2" height="15" rx="1" fill="url(#bandGrad)"/>
          <rect x="-4" y="-29" width="8" height="3.2" rx="1.2" fill="url(#bandGrad)"/>
          <rect x="-3.4" y="-27" width="6.8" height="12.6" rx="2.4" fill="url(#sectionGrad)"/>
          <path d="M0,0 L-3.2,-12 Q-1.8,-14.6 0,-14.6 Q1.8,-14.6 3.2,-12 Z" fill="url(#nibGrad)" stroke="#9a7327" stroke-width="0.3"/>
          <line x1="0" y1="-1" x2="0" y2="-8" stroke="#8a6a26" stroke-width="0.6"/>
          <circle cx="0" cy="-8" r="1.1" fill="#8a6a26"/>
        </g>
      </g>
    </svg>
    """
}

/// A `WKWebView` that never participates in drag-and-drop, so PDF file drops
/// land on the SwiftUI `.onDrop` area behind the icon instead of being swallowed
/// by the web view.
///
/// `hitTest` returning `nil` makes mouse clicks fall through. Refusing
/// `registerForDraggedTypes` blocks the *outer* view from becoming a drag
/// destination, but WebKit actually registers drag types on internal subviews
/// after the page loads — those are handled by `disableDragAndDropRecursively()`
/// invoked from the navigation delegate's `didFinish`.
private final class PassthroughWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // Intentionally empty: block WebKit from becoming a drag destination.
    }
}

private extension NSView {
    /// Strip every registered drag type from this view and all descendants, so
    /// none of WebKit's internal subviews can intercept a file drop.
    func disableDragAndDropRecursively() {
        unregisterDraggedTypes()
        for sub in subviews { sub.disableDragAndDropRecursively() }
    }
}
