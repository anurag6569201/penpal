//
//  DemoStrokeRecorder.swift
//  penpal
//
//  Dedicated recording studio for capturing user Apple Pencil strokes.
//
//  Features:
//  - Ruled paper background matching Penpal's exact 768 coordinate space
//  - Optical template guidelines indicating where and what to write
//  - Real-time PencilKit ink capture with pressure and tilt preserved
//  - Step-by-step progress tracking across all 13 demo script items
//  - Instant export of JSON recordings via standard iOS share sheet
//

import SwiftUI
import PencilKit
import UIKit

struct DemoStrokeRecorder: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DemoStrokeStore.shared

    @State private var currentIndex: Int = 0
    @State private var drawing = PKDrawing()
    @State private var canvasProxy = RecorderCanvasProxy()
    @State private var showExportSheet = false
    @State private var exportURL: URL?
    @State private var toastMessage: String?

    private var items: [RecordingScriptItem] { RecordingScriptItem.all }
    private var currentItem: RecordingScriptItem { items[currentIndex] }

    private var recordedCount: Int {
        items.filter { store.isRecorded($0.id) }.count
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                scriptSidebar
                    .frame(width: 320)
                    .background(Pen.paperRaised)
                    .overlay(Rectangle().fill(Pen.rule).frame(width: 1), alignment: .trailing)

                VStack(spacing: 0) {
                    itemHeader
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(Pen.paperRaised)
                        .overlay(Rectangle().fill(Pen.rule).frame(height: 1), alignment: .bottom)

                    ZStack {
                        RuledPaperBackground(lineGap: 44)

                        // Optical target box & ghost prompt
                        guidelinesView

                        // PencilKit canvas
                        RecorderCanvasRepresentable(
                            drawing: $drawing,
                            proxy: canvasProxy
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Pen.paper)
            .navigationTitle("Apple Pencil Demo Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if let url = store.exportDirectoryURL() {
                            exportURL = url
                            showExportSheet = true
                        }
                    } label: {
                        Label("Export All", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.recordings.isEmpty)
                }
            }
            .sheet(isPresented: $showExportSheet) {
                if let url = exportURL {
                    ActivityView(items: [url])
                }
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(Pen.sub.weight(.semibold))
                        .foregroundStyle(Pen.onAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Pen.inkAccent, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Pen.spring, value: toastMessage)
            .onAppear {
                loadCurrentItemTake()
            }
        }
    }

    // MARK: - Sidebar

    private var scriptSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECORDING SCRIPT")
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(Pen.inkFaded)

                HStack {
                    Text("\(recordedCount) of \(items.count) recorded")
                        .font(Pen.headline)
                        .foregroundStyle(Pen.inkPrimary)
                    Spacer()
                    ProgressView(value: Double(recordedCount), total: Double(items.count))
                        .frame(width: 70)
                        .tint(Pen.inkAccent)
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        let isSelected = idx == currentIndex
                        let isDone = store.isRecorded(item.id)

                        Button {
                            switchToIndex(idx)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isDone ? Pen.inkPositive : Pen.inkFaded.opacity(0.4))
                                    .font(.title3)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Pen.inkAccent : Pen.inkPrimary)
                                    Text(item.prompt)
                                        .font(.caption)
                                        .foregroundStyle(Pen.inkFaded)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(isSelected ? Pen.accentWash : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Header Controls

    private var itemHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Item \(currentIndex + 1) of \(items.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Pen.inkAccent)
                    if store.isRecorded(currentItem.id) {
                        Label("Recorded", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Pen.inkPositive)
                    }
                }

                Text(currentItem.title)
                    .font(Pen.titleSerif)
                    .foregroundStyle(Pen.inkPrimary)

                Text(currentItem.instructions)
                    .font(Pen.sub)
                    .foregroundStyle(Pen.inkFaded)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    canvasProxy.canvasView?.drawing = PKDrawing()
                    drawing = PKDrawing()
                } label: {
                    Label("Clear", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Pen.paper, in: Capsule())
                        .overlay(Capsule().strokeBorder(Pen.inkPrimary.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button {
                    saveCurrentTake()
                } label: {
                    Label("Save Take", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Pen.onAccent)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Pen.inkAccent, in: Capsule())
                }
                .buttonStyle(.plain)

                Divider().frame(height: 24)

                Button {
                    if currentIndex > 0 { switchToIndex(currentIndex - 1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 40, height: 40)
                        .background(Pen.paper, in: Circle())
                }
                .disabled(currentIndex == 0)
                .buttonStyle(.plain)

                Button {
                    if currentIndex < items.count - 1 { switchToIndex(currentIndex + 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 40, height: 40)
                        .background(Pen.paper, in: Circle())
                }
                .disabled(currentIndex == items.count - 1)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Guidelines

    private var guidelinesView: some View {
        let box = currentItem.suggestedBox
        return ZStack(alignment: .topLeading) {
            Color.clear

            // Dashed outline box
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    Pen.inkAccent.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .frame(width: box.width, height: box.height)
                .overlay(
                    Text(currentItem.prompt)
                        .font(.system(size: 24, weight: .regular, design: .serif))
                        .foregroundStyle(Pen.inkPrimary.opacity(0.25))
                        .padding(8),
                    alignment: .leading
                )
                .position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Actions

    private func switchToIndex(_ index: Int) {
        currentIndex = index
        loadCurrentItemTake()
    }

    private func loadCurrentItemTake() {
        if let existing = store.stroke(for: currentItem.id) {
            let loadedDrawing = existing.toPKDrawing(
                at: currentItem.suggestedAnchor,
                ink: PKInk(.pen, color: UIColor(Pen.inkAccent))
            )
            drawing = loadedDrawing
            canvasProxy.canvasView?.drawing = loadedDrawing
        } else {
            drawing = PKDrawing()
            canvasProxy.canvasView?.drawing = PKDrawing()
        }
    }

    private func saveCurrentTake() {
        let currentDrawing = canvasProxy.canvasView?.drawing ?? drawing
        guard !currentDrawing.strokes.isEmpty else {
            showToast("Draw with your Apple Pencil first!")
            return
        }

        let recordedStroke = DemoStroke.from(
            drawing: currentDrawing,
            id: currentItem.id,
            title: currentItem.title,
            prompt: currentItem.prompt,
            anchor: currentItem.suggestedAnchor
        )

        store.save(recordedStroke)
        Pen.tapHaptic()
        showToast("Saved take for \(currentItem.title)")

        // Advance to next unrecorded item if available
        if let nextUnrecorded = items.indices.first(where: { $0 > currentIndex && !store.isRecorded(items[$0].id) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                switchToIndex(nextUnrecorded)
            }
        }
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toastMessage == msg { toastMessage = nil }
        }
    }
}

// MARK: - Recorder Canvas Proxy & Representable

final class RecorderCanvasProxy {
    weak var canvasView: PKCanvasView?
}

struct RecorderCanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let proxy: RecorderCanvasProxy

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(Pen.inkAccent), width: 3.5)
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        proxy.canvasView = canvas
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: RecorderCanvasRepresentable

        init(_ parent: RecorderCanvasRepresentable) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
