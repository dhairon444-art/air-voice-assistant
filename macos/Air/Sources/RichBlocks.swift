import AppKit
import SwiftUI
import WebKit

/// Something Aria put on screen instead of saying it: a table, a Mermaid diagram, links, code or Markdown.
struct DisplayBlock: Identifiable, Equatable {
    let id = UUID()
    let kind: String
    let body: String
}

struct DisplayBlockView: View {
    let block: DisplayBlock
    var body: some View {
        Group {
            switch block.kind {
            case "table": MarkdownTableView(markdown: block.body)
            case "mermaid": MermaidBlock(source: block.body)
            case "code": CodeBlockView(code: block.body)
            default: MarkdownTextView(markdown: block.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Markdown (links, lists, bold): native text, links open in the default browser

struct MarkdownTextView: View {
    let markdown: String

    /// Line-level Markdown: headings, nested bullet and numbered lists, quotes and callouts
    /// ("> **Note:** …"), rules, fenced code and pipe tables; inline bold, italics, code and links.
    private enum Piece: Identifiable {
        case heading(Int, String), bullet(Int, String, String), quote(String), rule, para(String)
        case table(String), code(String)
        var id: String {
            switch self {
            case .heading(let l, let t): return "h\(l)\(t)"
            case .bullet(let d, let m, let t): return "b\(d)\(m)\(t)"
            case .quote(let t): return "q\(t)"
            case .rule: return "r\(UUID())"
            case .para(let t): return "p\(t)"
            case .table(let t): return "t\(t)"
            case .code(let t): return "c\(t)"
            }
        }
    }

    private var pieces: [Piece] {
        var out: [Piece] = []
        var lines = markdown.components(separatedBy: "\n")[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let t = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count / 2
            if t.hasPrefix("```") {
                var body: [String] = []
                while let l = lines.first, !l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(l); lines = lines.dropFirst() }
                lines = lines.dropFirst()
                out.append(.code(body.joined(separator: "\n")))
            } else if t.hasPrefix("|") {
                var rows = [t]
                while let l = lines.first, l.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(l.trimmingCharacters(in: .whitespaces)); lines = lines.dropFirst() }
                out.append(.table(rows.joined(separator: "\n")))
            } else if t.hasPrefix("#") {
                let level = t.prefix { $0 == "#" }.count
                out.append(.heading(level, t.trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                out.append(.bullet(indent, "•", String(t.dropFirst(2))))
            } else if let r = t.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                out.append(.bullet(indent, String(t[r]).trimmingCharacters(in: .whitespaces), String(t[r.upperBound...])))
            } else if t.hasPrefix(">") {
                out.append(.quote(t.trimmingCharacters(in: CharacterSet(charactersIn: "> "))))
            } else if t == "---" || t == "***" {
                out.append(.rule)
            } else if !t.isEmpty {
                out.append(.para(t))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                switch p {
                case .heading(let l, let t):
                    Text(inline(t)).font(l <= 1 ? .title3.weight(.semibold) : (l == 2 ? .headline : .subheadline.weight(.semibold)))
                        .padding(.top, 4)
                case .bullet(let depth, let mark, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(mark).foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                case .quote(let t):
                    let kind = ["note", "tip", "warning", "key takeaway", "important"].first { t.lowercased().hasPrefix("**\($0)") || t.lowercased().hasPrefix($0) }
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(kind == "warning" ? Color.orange : Color.accentColor).frame(width: 3)
                        Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background((kind == "warning" ? Color.orange : Color.accentColor).opacity(kind == nil ? 0.05 : 0.10),
                                in: RoundedRectangle(cornerRadius: 8))
                case .rule:
                    Divider().padding(.vertical, 4)
                case .para(let t):
                    Text(inline(t)).fixedSize(horizontal: false, vertical: true)
                case .table(let t):
                    MarkdownTableView(markdown: t)
                case .code(let c):
                    CodeBlockView(code: c)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: Tables: native grid, scrolls sideways when wide

struct MarkdownTableView: View {
    let markdown: String
    @Environment(\.amoled) private var amoled

    private var rows: [[String]] {
        markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("|") && !$0.replacingOccurrences(of: "|", with: "").allSatisfy { "-: ".contains($0) } }
            .map { line in
                var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                return cells
            }
    }

    var body: some View {
        let r = rows
        let cols = r.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(r.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            Text(cellText(c < row.count ? row[c] : ""))
                                .font(i == 0 ? .callout.weight(.semibold) : .callout)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                                .background(i == 0 ? Color.secondary.opacity(amoled ? 0.18 : 0.12) : (i % 2 == 0 ? Color.secondary.opacity(0.05) : .clear))
                        }
                    }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .textSelection(.enabled)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Table with \(max(0, r.count - 1)) rows")
    }

    private func cellText(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: Code

struct CodeBlockView: View {
    let code: String
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                Text(code).font(.callout.monospaced()).textSelection(.enabled).padding(10)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).padding(6).help("Copy")
        }
        .panelBackground(in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Mermaid: rendered offline with the bundled mermaid.js, zoomable, opens larger on click

struct MermaidBlock: View {
    let source: String
    @State private var height: CGFloat = 160
    @State private var large = false
    var body: some View {
        MermaidWebView(source: source, height: $height)
            .frame(height: min(max(height, 80), 420))
            .overlay(alignment: .topTrailing) {
                Button { large = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).padding(6).help("Open larger (pinch to zoom)")
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .sheet(isPresented: $large) {
                VStack(spacing: 0) {
                    MermaidWebView(source: source, height: .constant(600), zoomable: true)
                    HStack { Spacer(); Button("Done") { large = false }.keyboardShortcut(.cancelAction) }.padding(10)
                }
                .frame(minWidth: 760, minHeight: 560)
            }
            .accessibilityLabel("Diagram")
    }
}

struct MermaidWebView: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat
    var zoomable = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.amoled) private var amoled

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "size")
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.setValue(false, forKey: "drawsBackground")
        v.allowsMagnification = zoomable
        v.navigationDelegate = context.coordinator
        load(v)
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {}

    private func load(_ v: WKWebView) {
        guard let page = Bundle.main.url(forResource: "mermaid", withExtension: "html", subdirectory: "ui/vendor") else { return }
        (v.navigationDelegate as? Coordinator)?.pending = (source, scheme == .dark || amoled)
        // Local only: the template and mermaid.js load from the app bundle.
        v.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var pending: (String, Bool)?
        init(height: Binding<CGFloat>) { self.height = height }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let (src, dark) = pending,
                  let data = try? JSONSerialization.data(withJSONObject: [src]),
                  let arr = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("render(\(arr)[0], \(dark))")
        }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            if let h = message.body as? Double { DispatchQueue.main.async { self.height.wrappedValue = CGFloat(h) + 8 } }
        }
        // Links in diagrams open in the browser; nothing else navigates.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let u = action.request.url {
                NSWorkspace.shared.open(u); decisionHandler(.cancel); return
            }
            decisionHandler(action.request.url?.isFileURL == true || action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
