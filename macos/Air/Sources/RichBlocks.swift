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
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") {
                    Text(inline(t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))).font(.headline)
                } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(t.hasPrefix("- ") || t.hasPrefix("* ") ? "•" : String(t.prefix { $0 != " " }))
                            .foregroundStyle(.secondary)
                        Text(inline(t.hasPrefix("- ") || t.hasPrefix("* ") ? String(t.dropFirst(2))
                                    : String(t.drop { $0 != " " }.dropFirst())))
                    }
                } else if !t.isEmpty {
                    Text(inline(t))
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
