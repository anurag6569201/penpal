//
//  PenpalSettingsView.swift
//  penpal
//
//  Former ContentView settings — now opened from the Notes ⋯ menu.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PenpalSettingsView: View {
    @ObservedObject var settings: HandwritingSettings
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .style
    @State private var health: PenpalAPI.VerificationHealth?
    @State private var accessToken = PenpalAPI.accessToken
    @StateObject private var hands = HandProfiles.shared
    @State private var newHandName = ""
    @State private var showInsights = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var showDemoRecorder = false
    @State private var showImporter = false
    @State private var pendingImportURL: URL?
    @State private var showImportChoices = false
    @State private var showReplaceConfirm = false
    @State private var importError: String?
    @StateObject private var notes = NotesStore.shared
    @State private var showBackupImporter = false
    @State private var pendingBackupURL: URL?
    @State private var showRestoreConfirm = false
    @State private var previewText = "Today is a good day."
    var onStatus: (String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case style = "Style"
        case page = "Page"
        case behavior = "Behavior"
        var id: String { rawValue }
    }

    static let replyFonts: [(name: String, display: String)] = [
        ("SnellRoundhand", "Snell Roundhand"),
        ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("Noteworthy-Light", "Noteworthy"),
        ("MarkerFelt-Thin", "Marker Felt"),
        ("Georgia-Italic", "Georgia Italic"),
        ("AmericanTypewriter", "Typewriter"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Form {
                    Section {
                        HStack(spacing: 16) {
                            PenpalAnimatedLogoView(size: 64, mode: .interactive)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Make room for your thoughts.")
                                    .font(.system(.title3, design: .serif))
                                Text("Your notebook, your way.")
                                    .font(Pen.sub).foregroundStyle(Pen.inkFaded)
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(Pen.paperRaised)
                    }
                    switch tab {
                    case .style: styleSettings
                    case .page: pageSettings
                    case .behavior: behaviorSettings
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Pen.paper.ignoresSafeArea())
            // Sheets don't reliably inherit the app-root .tint() — without
            // this, every native control (segmented picker, sliders,
            // toggles) falls back to a default grey/white selection instead
            // of the app's own teal, which is the "random white patch"
            // the settings sheet was showing.
            .tint(Pen.inkAccent)
            .navigationTitle("Penpal Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Pen.paper, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                ActivityView(items: shareItems)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        pendingImportURL = try Self.stagingCopy(of: url)
                        showImportChoices = true
                    } catch {
                        importError = error.localizedDescription
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $showBackupImporter,
                allowedContentTypes: [Self.notebookBackupType],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        pendingBackupURL = try Self.stagingCopy(of: url)
                        showRestoreConfirm = true
                    } catch {
                        importError = error.localizedDescription
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .confirmationDialog("Import glyphs", isPresented: $showImportChoices, titleVisibility: .visible) {
                Button("Create new hand") {
                    importAsNewHand()
                }
                if hands.active != nil {
                    Button("Replace “\(hands.active?.name ?? "current")”", role: .destructive) {
                        showReplaceConfirm = true
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingImportURL = nil
                }
            } message: {
                Text("Save as its own hand, or overwrite the training on the hand you’re using now.")
            }
            .confirmationDialog(
                "Replace “\(hands.active?.name ?? "this hand")”?",
                isPresented: $showReplaceConfirm,
                titleVisibility: .visible
            ) {
                Button("Replace training", role: .destructive) {
                    importReplacingActive()
                }
                Button("Cancel", role: .cancel) {
                    pendingImportURL = nil
                }
            } message: {
                Text("The letters you’ve trained on this hand will be overwritten. Notes are not affected.")
            }
            .confirmationDialog(
                "Restore notebook backup?",
                isPresented: $showRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Merge backup") {
                    restoreNotebookBackup()
                }
                Button("Cancel", role: .cancel) {
                    pendingBackupURL = nil
                }
            } message: {
                Text("This adds notes that aren’t already on this iPad. It never replaces or deletes your current notes.")
            }
            .alert("Couldn’t import", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .fullScreenCover(isPresented: $showDemoRecorder) {
                DemoStrokeRecorder()
            }
        }
    }

    @ViewBuilder private var styleSettings: some View {
        writingPreview
        replyAppearance
        if settings.replyStyle == "hand" {
            writingLayout
            handwritingFinish
        }
        handwritingProfiles
        handwritingInsights
    }

    private var replyAppearance: some View {
        Section {
            Picker("Reply style", selection: $settings.replyStyle) {
                Text("My handwriting").tag("hand")
                Text("Typeface").tag("font")
            }
            .pickerStyle(.segmented)
            if settings.replyStyle == "font" {
                Picker("Typeface", selection: $settings.replyFontName) {
                    ForEach(Self.replyFonts, id: \.name) { font in
                        Text(font.display).font(.custom(font.name, size: 20)).tag(font.name)
                    }
                }
            }

            Divider().padding(.vertical, 3)

            LabeledContent("Ink color", value: settings.inkColorName == "active"
                           ? "Match my pen" : settings.inkColorName.capitalized)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                ForEach([("indigo", UIColor.systemIndigo), ("blue", UIColor.systemBlue),
                         ("black", UIColor.black), ("green", UIColor.systemGreen),
                         ("purple", UIColor.systemPurple)], id: \.0) { name, color in
                    inkSwatchButton(name: name, fill: AnyShapeStyle(Color(color)))
                }
            }
            .padding(.vertical, 4)
            Button {
                settings.inkColorName = "active"
            } label: {
                HStack {
                    Label("Match my pen color", systemImage: "applepencil.tip")
                    Spacer()
                    if settings.inkColorName == "active" {
                        Image(systemName: "checkmark").fontWeight(.semibold)
                    }
                }
            }
            ColorPicker("Custom color…", selection: Binding(
                get: { Color(UIColor(hex: settings.customColorHex) ?? .systemIndigo) },
                set: { newColor in
                    settings.customColorHex = UIColor(newColor).hexString
                    settings.inkColorName = "custom"
                }
            ), supportsOpacity: false)
        } header: {
            Label("Reply appearance", systemImage: "paintpalette")
        } footer: {
            Text("Applies to new Penpal replies. Your existing notes and the ink you draw with stay unchanged.")
        }
    }

    private var handwritingProfiles: some View {
        Section {
            ForEach(hands.profiles) { profile in
                Button {
                    hands.activate(profile.id)
                } label: {
                    HStack {
                        Label(profile.name, systemImage: "hand.draw")
                            .foregroundStyle(Pen.inkPrimary)
                        Spacer()
                        if hands.active?.id == profile.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField("New hand's name", text: $newHandName)
                    .textInputAutocapitalization(.words)
                Button("Add") {
                    let created = hands.addProfile(named: newHandName)
                    hands.activate(created.id)
                    newHandName = ""
                    onStatus("Switched to a fresh hand — train it from Teach it your hand.")
                }
                .disabled(newHandName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button {
                exportActiveGlyphs()
            } label: {
                Label("Export glyphs", systemImage: "square.and.arrow.up")
            }
            .disabled(!PersonalFontStore.shared.hasTraining)
            Button {
                showImporter = true
            } label: {
                Label("Import glyphs…", systemImage: "square.and.arrow.down")
            }
        } header: {
            Label("Handwriting profiles", systemImage: "person.2")
        } footer: {
            Text("Each profile keeps its own training. Switch profiles when someone else uses this iPad, or export and import a `.penpalglyphs` file to move handwriting training to another device.")
        }
    }

    private var handwritingInsights: some View {
        // Keep observations opt-in: handwriting should be described, never graded.
        Section {
            DisclosureGroup("About your handwriting", isExpanded: $showInsights) {
                if HandwritingInsights.hasEnoughData {
                    ForEach(HandwritingInsights.current()) { insight in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: insight.systemImage)
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.title)
                                    .font(.subheadline.weight(.medium))
                                Text(insight.detail)
                                    .font(.caption)
                                    .foregroundStyle(Pen.inkFaded)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } else {
                    Text(HandwritingInsights.notEnoughDataMessage)
                        .font(.caption)
                        .foregroundStyle(Pen.inkFaded)
                }
            }
        } footer: {
            Text("A description of what Penpal has learned from your training, not a score.")
        }
    }

    private var handwritingFinish: some View {
        Section {
            LabeledContent("Stroke weight", value: settings.penWidthScale < 0.5 ? "Extra fine"
                           : settings.penWidthScale < 0.8 ? "Fine"
                           : settings.penWidthScale > 1.25 ? "Bold" : "Regular")
            Slider(value: $settings.penWidthScale, in: 0.2...1.8, step: 0.05)
                .accessibilityLabel("Reply stroke weight")
            LabeledContent("Curve smoothing", value: settings.smoothness < 0.02 ? "Off"
                           : "\(Int((settings.smoothness * 100).rounded()))%")
            Slider(value: $settings.smoothness, in: 0...1, step: 0.05)
            LabeledContent("Natural variation", value: settings.variation == 0 ? "Steady"
                           : "\(Int(settings.variation)) / 10")
            Slider(value: $settings.variation, in: 0...10, step: 1)
        } header: {
            Label("Handwriting finish", systemImage: "signature")
        } footer: {
            Text("Smoothing rounds curves. Variation adds gentle movement to generated replies. Match sizing also follows the height, slant and pen weight in the handwriting you send.")
        }
    }

    private var writingPreview: some View {
        Section {
            TextField("Try your own preview text", text: $previewText, axis: .vertical)
                .lineLimit(1...3)
                .onChange(of: previewText) { _, value in
                    if value.count > 120 { previewText = String(value.prefix(120)) }
                }
                .accessibilityLabel("Writing preview text")
            if settings.replyStyle == "hand" {
                GeometryReader { geometry in
                    HandwritingPreview(settings: settings, text: previewText.isEmpty ? "Today is a good day." : previewText, handID: hands.active?.id,
                                       width: geometry.size.width, height: geometry.size.height)
                }
                .frame(height: max(180, settings.resolvedSize(detected: 18) * 7))
            } else {
                Text(previewText.isEmpty ? "Today is a good day." : previewText)
                    .font(Font(ReplyInkStyle.typeface(name: settings.replyFontName,
                                                    xHeight: settings.resolvedSize(detected: 18))))
                    .foregroundStyle(Color(settings.inkColor))
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        } header: {
            Label("Writing preview", systemImage: "eye")
        } footer: {
            Text(settings.replyStyle == "font"
                 ? "Try different text to preview new replies in your selected typeface and color."
                 : PersonalFontStore.shared.hasTraining
                 ? "Previewing your trained letters and saved words. Missing letters use Penpal’s built-in handwriting."
                 : "Teach Penpal your letters and words to preview your own handwriting here.")
        }
        .listRowBackground(Pen.paper)
    }

    private func inkSwatchButton(name: String, fill: AnyShapeStyle) -> some View {
        Button {
            settings.inkColorName = name
        } label: {
            Circle()
                .fill(fill)
                .frame(width: 30, height: 30)
                .overlay {
                    if settings.inkColorName == name {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle().stroke(
                        settings.inkColorName == name
                            ? Pen.inkAccent : .clear, lineWidth: 2.5)
                        .padding(-4)
                }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(name.capitalized + " reply ink")
        .accessibilityAddTraits(settings.inkColorName == name ? [.isSelected] : [])
    }

    @ViewBuilder private var pageSettings: some View {
        writingPreview
        Section {
            Toggle("Apple Pencil only", isOn: $settings.pencilOnly)
        } header: {
            Label("Drawing input", systemImage: "hand.draw")
        } footer: {
            Text("When enabled, your finger scrolls and operates page controls. Turn it off to draw with a finger instead.")
        }
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)],
                      spacing: 12) {
                ForEach([("ruled", "Ruled"), ("grid", "Grid"),
                         ("dots", "Dots"), ("blank", "Blank")], id: \.0) { tag, name in
                    Button {
                        settings.paperStyle = tag
                    } label: {
                        VStack(spacing: 6) {
                            paperPreview(tag)
                                .frame(height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(settings.paperStyle == tag
                                                ? Pen.inkAccent : Pen.inkFaded.opacity(0.25),
                                                lineWidth: settings.paperStyle == tag ? 2.5 : 1)
                                }
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(settings.paperStyle == tag
                                                 ? Pen.inkPrimary : Pen.inkFaded)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("Paper", systemImage: "doc.plaintext")
        }

    }

    @ViewBuilder private var writingLayout: some View {
        Section {
            Picker("Size", selection: $settings.sizeMode) {
                Text("Match").tag(HandwritingSizeMode.adaptive)
                Text("Page").tag(HandwritingSizeMode.automatic)
                Text("Fixed").tag(HandwritingSizeMode.manual)
            }
            .pickerStyle(.segmented)
            if settings.sizeMode != .automatic {
                LabeledContent(settings.sizeMode == .adaptive ? "Fallback height" : "Letter height",
                               value: "\(Int(settings.manualSize)) pt")
                Slider(value: $settings.manualSize, in: 10...42, step: 1)
            }
        } header: {
            Label("Letter size", systemImage: "textformat.size")
        } footer: {
            Text(settings.sizeMode == .adaptive
                 ? "Match follows the size, slant and pen weight in the handwriting you send. If there isn’t enough to measure, replies use the fallback height above."
                 : settings.sizeMode == .automatic
                 ? "Page follows the notebook’s writing lines."
                 : "Fixed keeps lowercase letters at your chosen height.")
        }

        if settings.replyStyle == "hand" {
            Section {
                LabeledContent("Letter spacing",
                               value: String(format: "%.1f×", settings.letterSpacingScale))
                Slider(value: $settings.letterSpacingScale, in: 0.7...1.5, step: 0.05)
                LabeledContent("Word spacing",
                               value: String(format: "%.1f×", settings.wordSpacingScale))
                Slider(value: $settings.wordSpacingScale, in: 0.7...1.6, step: 0.05)
                LabeledContent("Line spacing",
                               value: String(format: "%.1f×", settings.lineSpacingScale))
                Slider(value: $settings.lineSpacingScale, in: 0.8...1.8, step: 0.05)
            } header: {
                Label("Spacing", systemImage: "arrow.left.and.right.text.vertical")
            } footer: {
                Text("Adjust the gaps between letters, words and lines in new handwritten replies.")
            }
        }
    }

    private func paperPreview(_ style: String) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Pen.paper))
            let line = Pen.inkFaded.opacity(0.45)
            switch style {
            case "grid":
                var x: CGFloat = 8
                while x < size.width {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 4))
                                      $0.addLine(to: CGPoint(x: x, y: size.height - 4)) },
                               with: .color(line.opacity(0.6)), lineWidth: 0.6)
                    x += 12
                }
                var gy: CGFloat = 10
                while gy < size.height {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 4, y: gy))
                                      $0.addLine(to: CGPoint(x: size.width - 4, y: gy)) },
                               with: .color(line.opacity(0.6)), lineWidth: 0.6)
                    gy += 12
                }
            case "dots":
                var dy: CGFloat = 10
                while dy < size.height {
                    var dx: CGFloat = 10
                    while dx < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: dx - 1, y: dy - 1,
                                                        width: 2, height: 2)),
                                 with: .color(line))
                        dx += 12
                    }
                    dy += 12
                }
            case "blank":
                break
            default:
                var ry: CGFloat = 14
                while ry < size.height {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 4, y: ry))
                                      $0.addLine(to: CGPoint(x: size.width - 4, y: ry)) },
                               with: .color(line), lineWidth: 0.8)
                    ry += 12
                }
            }
        }
    }

    @ViewBuilder private var behaviorSettings: some View {
        // PEN-04 — verification health, stated plainly. If answers are going
        // out unchecked the user should hear it from us, not discover it.
        Section {
            HStack(spacing: 10) {
                Image(systemName: health.map { $0.isHealthy ? "checkmark.seal.fill"
                                                            : "exclamationmark.triangle.fill" }
                      ?? "questionmark.circle")
                    .foregroundStyle(health.map { $0.isHealthy ? Pen.inkPositive : Pen.inkCaution }
                                     ?? Pen.inkFaded)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health?.summary ?? "Checking…")
                        .font(.subheadline)
                    if let health, health.solves > 0 {
                        Text("\(health.solves) solved · \(health.cas_hits) computed exactly"
                             + (health.corrections_applied > 0
                                ? " · \(health.corrections_applied) rewritten" : ""))
                            .font(.caption)
                            .foregroundStyle(Pen.inkFaded)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
        } header: {
            Label("Answer checking", systemImage: "checkmark.shield")
        } footer: {
            Text("Every solution is re-derived by a second, independent pass before it's written. Exact results come from a computer-algebra engine where possible.")
        }
        .task { health = await PenpalAPI.verificationHealth(baseURL: settings.apiBaseURL) }

        Section {
            Toggle("Gemini brain", isOn: $settings.useBrain)
            TextField("API base URL", text: $settings.apiBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Access token (optional)", text: $accessToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: accessToken) { _, value in
                    PenpalAPI.accessToken = value
                }
            Button("Reset conversation") {
                ConversationStore.shared.reset()
                onStatus("Conversation cleared.")
            }
        } header: {
            Label("Brain", systemImage: "brain.head.profile")
        } footer: {
            Text("Penpal pen reads handwriting on-device, then sends text to Django → Gemini.\n\nLeave the token blank when running the brain locally. A deployed brain requires one (it matches PENPAL_TOKENS on the server).")
        }

        Section {
            Toggle("Confirm before solving", isOn: $settings.confirmBeforeSolving)
        } header: {
            Label("Calculator", systemImage: "equal.circle")
        } footer: {
            Text(settings.confirmBeforeSolving
                 ? "After you write an expression ending in \"=\", Penpal shows how it read your ink with a Solve button. Nothing is calculated until you tap Solve."
                 : "Expressions ending in \"=\" are solved and written immediately.")
        }

        Section {
            Button {
                exportNotebookBackup()
            } label: {
                Label("Export notebook backup", systemImage: "externaldrive.badge.checkmark")
            }
            Button {
                showBackupImporter = true
            } label: {
                Label("Restore notebook backup…", systemImage: "externaldrive.badge.plus")
            }
            Button {
                NotesStore.shared.restoreGuide()
                onStatus("Penpal Guide restored.")
            } label: {
                Label("Restore Penpal Guide", systemImage: "book.pages")
            }
        } header: {
            Label("Notes & recovery", systemImage: "externaldrive")
        } footer: {
            Text("A backup is one portable `.penpalbackup` file containing your notes and attachments. Keep it in Files, iCloud Drive, Google Drive, or an external disk. Restoring merges safely; it never overwrites this iPad’s library.")
        }

        Section {
            Picker("Writing indicator", selection: $settings.writingIndicator) {
                ForEach(PenpalWritingIndicator.allCases) { indicator in
                    Text(indicator.title).tag(indicator)
                }
            }
            Text("A small Penpal nib follows the ink, then lifts away. With Reduce Motion, it rests beside the start of the reply. Instant replies show no indicator.")
                .font(Pen.caption)
                .foregroundStyle(Pen.inkFaded)
            Picker("Writing pace", selection: $settings.writingPace) {
                ForEach(PenpalWritingPace.allCases) { pace in
                    Text(pace.title).tag(pace)
                }
            }
            .pickerStyle(.segmented)

            switch settings.writingPace {
            case .natural:
                LabeledContent("Natural speed", value: "\(Int(settings.speedLevel))")
                Slider(value: $settings.speedLevel, in: 1...10, step: 1)
            case .timed:
                LabeledContent(
                    "Finish within",
                    value: "\(Int(settings.timedWritingSeconds.rounded())) sec"
                )
                Slider(value: $settings.timedWritingSeconds, in: 1...30, step: 1)
            case .instant:
                Text("The complete response appears as ink immediately.")
                    .font(.caption)
                    .foregroundStyle(Pen.inkFaded)
            }
        } header: {
            Label("Replies", systemImage: "arrowshape.turn.up.left")
        } footer: {
            Text("Penpal never replies on its own. Tap Ask, or box a question, to send it — pausing while you write is never treated as sending. This controls how the reply is drawn once you do.")
        }

        Section {
            Toggle("Diagnostics", isOn: $settings.diagnostics)
            if settings.diagnostics {
                Button {
                    showDemoRecorder = true
                } label: {
                    Label("Record demo strokes (Apple Pencil)", systemImage: "pencil.and.outline")
                }
            }
            Button("Show gesture tips again") {
                GestureOnboarding.shared.reset()
                onStatus("Gesture tips will show next time you turn Penpal on.")
            }
        } header: {
            Label("Debug", systemImage: "waveform.path.ecg")
        } footer: {
            Text("Gestures: box a question to send it (or tap Ask) · double-underline your working to have it checked · strike through ink to delete it.")
        }
    }

    // MARK: - Glyph bank transfer

    private static let notebookBackupType = UTType(filenameExtension: "penpalbackup") ?? .data

    /// Copies a security-scoped picker URL into tmp so later dialogs don't
    /// race the scope being revoked.
    private static func stagingCopy(of url: URL) throws -> URL {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty
            ? PersonalFontStore.glyphBankExtension
            : url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    private func exportActiveGlyphs() {
        let name = hands.active?.name ?? "Hand"
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = "\(safe.isEmpty ? "Hand" : safe).\(PersonalFontStore.glyphBankExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try PersonalFontStore.shared.exportGlyphBank(to: url)
            shareItems = [url]
            showShare = true
            onStatus("Exported \(PersonalFontStore.shared.trainingSummary).")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func exportNotebookBackup() {
        do {
            let url = try notes.exportNotebookBackup()
            shareItems = [url]
            showShare = true
            onStatus("Notebook backup is ready to save.")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func restoreNotebookBackup() {
        guard let url = pendingBackupURL else { return }
        defer { pendingBackupURL = nil }
        do {
            let summary = try notes.restoreNotebookBackup(from: url)
            var message = "Restored \(summary.importedNotes) note"
                + (summary.importedNotes == 1 ? "" : "s")
            if summary.importedFolders > 0 {
                message += " and \(summary.importedFolders) folder"
                    + (summary.importedFolders == 1 ? "" : "s")
            }
            if summary.skippedExistingNotes > 0 {
                message += ". \(summary.skippedExistingNotes) existing note"
                    + (summary.skippedExistingNotes == 1 ? " was" : "s were") + " kept"
            }
            if summary.skippedMissingAttachments > 0 {
                message += ". \(summary.skippedMissingAttachments) missing attachment"
                    + (summary.skippedMissingAttachments == 1 ? " was" : "s were") + " skipped"
            }
            onStatus(message + ".")
        } catch {
            importError = error.localizedDescription
        }
    }

    private func withPendingImport(_ body: (URL) throws -> Void) {
        guard let url = pendingImportURL else { return }
        defer { pendingImportURL = nil }
        do {
            try body(url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importAsNewHand() {
        withPendingImport { url in
            let profile = try hands.importGlyphBank(from: url, named: "")
            onStatus("Imported “\(profile.name)” — \(PersonalFontStore.shared.trainingSummary).")
        }
    }

    private func importReplacingActive() {
        withPendingImport { url in
            try PersonalFontStore.shared.installGlyphBank(from: url)
            onStatus("Replaced “\(hands.active?.name ?? "hand")” — \(PersonalFontStore.shared.trainingSummary).")
        }
    }
}
