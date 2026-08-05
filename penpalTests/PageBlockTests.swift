import XCTest
@testable import penpal

final class PageBlockTests: XCTestCase {
    func testLegacyBlockWithoutKindDecodesAndInfersTable() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "html": "<table><tr><td>Value</td></tr></table>",
          "x": 12,
          "y": 24,
          "width": 320,
          "height": 180,
          "createdAt": 0
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let block = try decoder.decode(CodeBlock.self, from: json)

        XCTAssertNil(block.kind)
        XCTAssertEqual(block.resolvedKind, .table)
        XCTAssertEqual(block.frame.origin.x, 12)
    }

    func testExplicitBlockKindRoundTrips() throws {
        let original = CodeBlock(
            html: CodedPaper.checklistBlockHTML,
            kind: .checklist,
            x: 20,
            y: 40,
            width: 360,
            height: 220
        )

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CodeBlock.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.resolvedKind, .checklist)
    }

    func testInteractiveBlockKindRoundTripsAndCanBeInferred() throws {
        let source = """
        <div data-penpal-kind="interactive"><button>Try it</button></div>
        """
        let original = CodeBlock(
            html: source,
            kind: .interactive,
            x: 20,
            y: 40,
            width: 360,
            height: 320
        )
        let restored = try JSONDecoder().decode(
            CodeBlock.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored.resolvedKind, .interactive)

        var legacy = original
        legacy.kind = nil
        XCTAssertEqual(legacy.resolvedKind, .interactive)
    }

    func testInteractiveDocumentUsesConsentGeneratedPolicy() {
        let source = "<button id=\"go\">Go</button><script>go.onclick=()=>{}</script>"
        let policy = InteractiveRuntimePolicy.contentSecurityPolicy(
            persistentDomains: ["cdn.jsdelivr.net"]
        )
        let document = CodedPaper.interactiveDocument(
            from: source,
            contentSecurityPolicy: policy
        )

        XCTAssertTrue(document.contains("Content-Security-Policy"))
        XCTAssertTrue(document.contains("default-src 'none'"))
        XCTAssertTrue(document.contains("wasm-unsafe-eval"))
        XCTAssertTrue(document.contains("https://cdn.jsdelivr.net"))
        XCTAssertTrue(document.contains(source))
    }

    func testInteractiveRuntimeMetadataRoundTripsWithTheBlock() throws {
        let manifest = InteractiveManifest(
            version: 1,
            domains: [
                InteractiveDomainRequest(host: "cdn.jsdelivr.net", reason: "Load D3")
            ],
            capabilities: [
                InteractiveCapabilityRequest(
                    id: "clipboard.write",
                    reason: "Copy a result"
                )
            ],
            dependencies: [
                InteractiveDependency(
                    url: "https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js",
                    kind: "script",
                    integrity: nil
                )
            ]
        )
        let block = CodeBlock(
            html: "<div>Chart</div>",
            kind: .interactive,
            x: 0,
            y: 0,
            width: 320,
            height: 240,
            runtime: InteractiveRuntimeMetadata(
                title: "Chart",
                manifest: manifest,
                allowedDomains: ["cdn.jsdelivr.net"],
                allowedCapabilities: ["clipboard.write"]
            )
        )
        let restored = try JSONDecoder().decode(
            CodeBlock.self,
            from: JSONEncoder().encode(block)
        )
        XCTAssertEqual(restored, block)
        XCTAssertEqual(restored.runtime?.manifest.dependencies.count, 1)
        XCTAssertEqual(restored.runtime?.isAutoRepairEnabled, true)
        XCTAssertEqual(restored.runtime?.completedRepairAttempts, 0)
    }

    func testRuntimeBridgeCapturesBoundedFailuresForSelfHealing() {
        let script = InteractiveRuntimeBridge.javaScript(
            domains: [],
            capabilities: []
        )
        XCTAssertTrue(script.contains("unhandledrejection"))
        XCTAssertTrue(script.contains("type: 'diagnostic'"))
        XCTAssertTrue(script.contains("reportCount >= 8"))
        XCTAssertFalse(script.contains("localStorage.getItem"))
        XCTAssertFalse(script.contains("document.body.innerHTML"))
    }

    func testRuntimePolicyRejectsPrivateHosts() {
        XCTAssertNil(InteractiveRuntimePolicy.normalizePublicHost("localhost"))
        XCTAssertNil(InteractiveRuntimePolicy.normalizePublicHost("192.168.1.4"))
        XCTAssertNil(InteractiveRuntimePolicy.normalizePublicHost("https://10.0.0.2/api"))
        XCTAssertEqual(
            InteractiveRuntimePolicy.normalizePublicHost(
                "HTTPS://CDN.JSDELIVR.NET/npm/d3"
            ),
            "cdn.jsdelivr.net"
        )
    }

    func testInteractiveIntentIsExplicitOrSpecialtyDriven() {
        XCTAssertTrue(PenpalAPI.shouldGenerateInteractive(
            message: "Build an interactive pendulum simulation",
            capability: "mathematician"
        ))
        XCTAssertTrue(PenpalAPI.shouldGenerateInteractive(
            message: "Explain photosynthesis",
            capability: "interactive"
        ))
        XCTAssertFalse(PenpalAPI.shouldGenerateInteractive(
            message: "Explain photosynthesis",
            capability: "companion"
        ))
    }

    func testTemplatesHaveTypedEditableMarkup() {
        XCTAssertTrue(CodedPaper.tableBlockHTML.contains("data-penpal-kind=\"table\""))
        XCTAssertTrue(CodedPaper.textBlockHTML.contains("data-penpal-editable=\"true\""))
        XCTAssertTrue(CodedPaper.checklistBlockHTML.contains("penpal-item-text"))
        XCTAssertTrue(CodedPaper.imageBlockHTML(base64JPEG: "AA==")
            .contains("data-penpal-kind=\"image\""))
    }
}
