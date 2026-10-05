import AppKit

/// Asks for a Hugging Face read token when the external transcriber's models are gated.
@MainActor
enum TokenPrompt {
    static let TOKENS_URL = URL(string: "https://huggingface.co/settings/tokens")!

    /// The trimmed token, or nil when cancelled.
    static func ask(_ request: TokenRequest) -> String? {
        let alert = NSAlert()
        alert.messageText = request.gateRejected ? "Hugging Face refused the token" : "Hugging Face token needed"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let explanation = NSMutableAttributedString()
        if request.gateRejected {
            explanation.append(NSAttributedString(string: "The token works, but the speaker model's conditions are not accepted yet. "))
            if let detail = request.detail { explanation.append(NSAttributedString(string: detail + "\n\n")) }
        }
        explanation.append(NSAttributedString(string: "pyannote's speaker model is gated on Hugging Face. Accept the conditions at "))
        explanation.append(link(request.gateURL.absoluteString, request.gateURL))
        explanation.append(NSAttributedString(string: " while signed in, then paste a read token from "))
        explanation.append(link("huggingface.co/settings/tokens", TOKENS_URL))
        explanation.append(NSAttributedString(string: "."))
        explanation.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                 range: NSRange(location: 0, length: explanation.length))

        let text = NSTextField(labelWithAttributedString: explanation)
        text.isSelectable = true
        text.allowsEditingTextAttributes = true
        text.preferredMaxLayoutWidth = 300
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "hf_…"
        let stack = NSStackView(views: [text, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func link(_ title: String, _ url: URL) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.link: url])
    }
}
