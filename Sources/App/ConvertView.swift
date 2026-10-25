import SwiftUI

struct ConvertView: View {
    @ObservedObject var model: ConvertModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(model: model)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider().opacity(0.6)

            Group {
                switch model.phase {
                case .editing: EditingView(model: model, close: close)
                case .running(let fraction): RunningView(fraction: fraction, model: model, cancel: { model.cancel(); close() }, hide: close)
                case .finished(let summary): FinishedView(summary: summary, reveal: { model.revealOutputs(); close() }, close: close)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .frame(width: 360)
        .background(VisualEffect().ignoresSafeArea())
        .animation(.snappy(duration: 0.22), value: model.phase)
    }
}

// MARK: - Header

private struct Header: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if model.files.count > 1 {
                    RoundedRectangle(cornerRadius: 8).fill(.background).stroke(.primary.opacity(0.15)).frame(width: 42, height: 42).rotationEffect(.degrees(-10)).offset(x: -5, y: 1)
                    RoundedRectangle(cornerRadius: 8).fill(.background).stroke(.primary.opacity(0.15)).frame(width: 42, height: 42).rotationEffect(.degrees(8)).offset(x: 5, y: 1)
                }
                Group {
                    if let image = model.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: placeholder).font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)))
                .overlay(alignment: .bottomTrailing) {
                    if model.kind == .video, model.thumbnail != nil {
                        Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.white)
                            .padding(3).background(.black.opacity(0.5), in: Circle()).padding(3)
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Text(model.actionTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .animation(.easeOut(duration: 0.15), value: model.subtitle)
    }

    private var placeholder: String {
        switch model.kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .office: "doc.text"
        }
    }
}

// MARK: - Editing

private struct EditingView: View {
    @ObservedObject var model: ConvertModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.formatChoices.count > 1 {
            Row("Format") {
                VStack(alignment: .leading, spacing: 6) {
                    Chips(items: model.formatChoices, selection: $model.settings.format, overflow: overflow, overflowTitle: overflowTitle) { f in
                        model.mode == .optimize && model.kind == .image && f == model.sourceFormat ? "Keep \(f.displayName)"
                            : f == .mp4hevc ? "HEVC"
                            : model.kind == .video && f.kind == .audio ? "\(f.displayName) (audio only)" : f.displayName
                    }
                    Text(model.kind == .video && model.settings.format.kind == .audio
                         ? "Saves just the sound. \(model.settings.format.blurb)." : model.settings.format.blurb)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }

            if model.mode == .optimize, model.kind == .image || model.kind == .video {
                Row("Preset") {
                    Chips(items: Preset.allCases, selection: Binding(get: { model.preset }, set: { model.selectPreset($0) })) {
                        $0.title(for: model.kind)
                    }
                }
            }

            if model.mode == .combine {
                CombineRows(model: model)
            } else if model.kind == .pdf {
                PDFRows(model: model)
            } else if model.kind == .image {
                ImageRows(model: model)
            } else if model.isGIFFromVideo {
                GIFRows(model: model)
            } else if model.settings.format.kind == .video {
                VideoRows(model: model)
            } else if model.settings.format.isLossyAudio {
                Row("Bitrate") {
                    Chips(items: [128, 192, 256, 320], selection: $model.settings.audio.bitrateKbps) { "\($0)k" }
                }
            }

            if let hint = model.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, rowLabelWidth + 12)
            }

            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, rowLabelWidth + 12)
            }

            Divider().opacity(0.6).padding(.horizontal, -18)

            HStack(spacing: 8) {
                Estimate(model: model)
                Spacer(minLength: 8)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(model.actionTitle, action: model.run)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isAlreadyCompact)
            }
            .controlSize(.large)
        }
        .padding(18)
        .animation(.snappy(duration: 0.2), value: model.settings.format)
    }

    /// Rarely used formats tuck into a menu; from a video, that's the audio-only options.
    private var overflow: [OutputFormat] {
        switch model.kind {
        case .image: [.tiff, .gif, .bmp]
        case .video: [.mov, .mkv, .mp3, .m4a, .wav]
        case .audio: [.aiff]
        case .pdf: [.heic, .tiff]
        case .office: []
        }
    }

    private var overflowTitle: String { "More" }
}

private struct ImageRows: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        let format = model.settings.format
        if format == .pdf {
            Row("Page") { PageSizeChips(model: model) }
            Row("Quality") { QualitySlider(value: $model.settings.image.quality) }
        }
        if format == .webp {
            Row("") { Toggle("Lossless", isOn: $model.settings.image.lossless).toggleStyle(.checkbox) }
        }
        if format.isLossy && !(format == .webp && model.settings.image.lossless) {
            Row("Quality") { QualitySlider(value: $model.settings.image.quality) }
        }
        Row("Size") {
            // Batches can mix sizes, so only a single file limits the choices.
            let longest = model.files.count == 1 ? model.imageInfo.map { max($0.pixelWidth, $0.pixelHeight) } : nil
            Picker("", selection: $model.settings.image.maxDimension) {
                Text(longest.map { "Original (\(String($0)) px)" } ?? "Original size").tag(Int?.none)
                Divider()
                ForEach([3840, 2560, 1920, 1280, 1024, 800, 512].filter { longest == nil || $0 < longest! }, id: \.self) { px in
                    Text("\(String(px)) px longest side").tag(Int?.some(px))
                }
            }
            .labelsHidden().fixedSize()
        }
        if format.keepsMetadata {
            Row("") { Toggle("Remove location & camera info", isOn: $model.settings.image.stripMetadata).toggleStyle(.checkbox) }
        }
    }
}

private struct VideoRows: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        Row("Quality") {
            VStack(alignment: .leading, spacing: 6) {
                Chips(items: VideoQuality.allCases.filter { $0 != .original || model.offersOriginalQuality }, selection: $model.settings.video.quality) { $0.title }
                if model.settings.video.quality == .original {
                    Text("Instant, no quality loss. Only the container changes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Row("Size") {
            let short = model.files.count == 1 ? model.info?.shortSide : nil
            Picker("", selection: $model.settings.video.maxShortSide) {
                Text(short.map { "Original (\(String($0))p)" } ?? "Original size").tag(Int?.none)
                Divider()
                ForEach([2160, 1440, 1080, 720, 480].filter { short == nil || $0 < short! }, id: \.self) { p in
                    Text(p == 2160 ? "4K (2160p)" : "\(String(p))p").tag(Int?.some(p))
                }
            }
            .labelsHidden().fixedSize()
        }
        if model.info?.hasAudio ?? true {
            Row("") { Toggle("Remove sound", isOn: $model.settings.video.removeAudio).toggleStyle(.checkbox) }
        }
    }
}

private struct GIFRows: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        Row("Width") {
            let source = model.files.count == 1 ? model.info?.width : nil
            Picker("", selection: $model.settings.gif.width) {
                ForEach([320, 480, 640, 800, 1080].filter { source == nil || $0 <= source! }, id: \.self) { Text("\(String($0)) px").tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        Row("Frames") {
            Chips(items: [10, 15, 24], selection: $model.settings.gif.fps) { "\($0) fps" }
        }
    }
}

private struct PDFRows: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        let format = model.settings.format
        if format == .pdf {
            Row("Quality") {
                VStack(alignment: .leading, spacing: 6) {
                    Chips(items: PDFQuality.allCases, selection: $model.settings.pdf.quality) { $0.title }
                    Text("Text and drawings stay sharp. Only pictures are compressed.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if format.kind == .image {
            Row("Size") {
                VStack(alignment: .leading, spacing: 6) {
                    Chips(items: [72, 150, 300], selection: $model.settings.pdf.dpi) { [72: "Screen", 150: "Standard", 300: "Print"][$0]! }
                    Text("\(model.settings.pdf.dpi) dpi").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if format.isLossy {
                Row("Quality") { QualitySlider(value: $model.settings.image.quality) }
            }
        }
    }
}

private struct CombineRows: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        Row("Order") {
            VStack(alignment: .leading, spacing: 6) {
                List {
                    ForEach(model.order, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(systemName: FormatCatalog.kind(of: url) == .pdf ? "doc.richtext" : "photo")
                                .foregroundStyle(.secondary).frame(width: 16)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            let pages = model.pageCounts[url] ?? 1
                            if FormatCatalog.kind(of: url) == .pdf {
                                Text(pages == 1 ? "1 page" : "\(pages) pages").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .font(.callout)
                    }
                    .onMove { model.order.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(model.order.count) * 24 + 8, 152))
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
            }
        }
        Row("Name") {
            HStack(spacing: 4) {
                TextField("Combined", text: $model.settings.pdf.outputName).textFieldStyle(.roundedBorder)
                Text(".pdf").foregroundStyle(.secondary)
            }
        }
        if model.order.contains(where: { FormatCatalog.kind(of: $0) == .image }) {
            Row("Page") { PageSizeChips(model: model) }
            Row("Quality") { QualitySlider(value: $model.settings.image.quality) }
        }
    }
}

private struct PageSizeChips: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chips(items: PageSize.allCases, selection: $model.settings.pdf.pageSize) { $0.title }
            Text(model.settings.pdf.pageSize == .image ? "Each page is shaped like its picture" : "Pictures fit the page, turned to match")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct QualitySlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: 0.3...1.0).controlSize(.small)
            Text("\(Int((value * 100).rounded()))")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

private struct Estimate: View {
    @ObservedObject var model: ConvertModel

    var body: some View {
        HStack(spacing: 6) {
            if model.mode == .combine {
                Text(model.totalPages == 1 ? "1 page" : "\(model.totalPages) pages")
                    .font(.callout.weight(.semibold)).monospacedDigit()
            } else if model.isAlreadyCompact {
                Label("Already compact", systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let estimate = model.estimate {
                let change = model.totalBytes > 0 ? Double(estimate - model.totalBytes) / Double(model.totalBytes) : 0
                // Image sizes are measured; media sizes are calculated from bitrates.
                let approximate = model.files.count > 1 || model.kind == .video || model.kind == .audio || model.totalPages > 1
                Text((approximate ? "≈ " : "") + ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file))
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(change <= 0 ? "−\(Int((-change * 100).rounded()))%" : "+\(Int((change * 100).rounded()))%")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(change <= 0 ? .green : .orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((change <= 0 ? Color.green : .orange).opacity(0.14), in: Capsule())
            } else if !model.estimating, model.kind != .office, ![.docx, .pptx].contains(model.settings.format) {
                Text("—").foregroundStyle(.secondary)
            }
            if model.estimating {
                ProgressView().controlSize(.mini)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.estimate)
        .help(model.kind == .video || model.kind == .audio ? "Estimated from the target bitrate" : "Measured by converting the first file")
    }
}

// MARK: - Running & finished

private struct RunningView: View {
    let fraction: Double
    @ObservedObject var model: ConvertModel
    let cancel: () -> Void
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verb + "…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            ProgressView(value: fraction).progressViewStyle(.linear)
            HStack {
                Text("You can hide this; you'll get a notification when it's done.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Stop", action: cancel)
                Button("Hide", action: hide).keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
        .padding(18)
        .animation(.smooth(duration: 0.25), value: fraction)
    }

    private var verb: String {
        switch model.actionTitle {
        case "Compress": "Compressing"
        case "Optimize": "Optimizing"
        case "Combine": "Combining"
        default: "Converting"
        }
    }
}

private struct FinishedView: View {
    let summary: ConvertModel.Summary
    let reveal: () -> Void
    let close: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(summary.written.isEmpty ? Color.secondary : Color.green)
                    .symbolEffect(.bounce, value: appeared)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                    if summary.skipped > 0 {
                        Text(summary.skipped == 1 && summary.written.isEmpty
                             ? "It's already as small as these settings can make it. Try a smaller preset."
                             : "\(summary.skipped) already as small as they get, left untouched.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(summary.failures, id: \.self) { f in
                        Text(f).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack {
                Spacer()
                if summary.written.isEmpty {
                    Button("Done", action: close).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Done", action: close).keyboardShortcut(.cancelAction)
                    Button("Show in Finder", action: reveal).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(18)
        .onAppear { appeared = true }
    }

    private var icon: String {
        if !summary.failures.isEmpty && summary.written.isEmpty { return "xmark.circle.fill" }
        return summary.written.isEmpty ? "checkmark.circle" : "checkmark.circle.fill"
    }

    private var headline: String { summary.headline }
    private var detail: String? { summary.detail }
}

// MARK: - Building blocks

private let rowLabelWidth: CGFloat = 58

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: rowLabelWidth, alignment: .trailing)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A segmented control that wraps and animates its selection highlight.
/// Items listed in `overflow` collapse into a trailing menu.
private struct Chips<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    var overflow: [Item] = []
    var overflowTitle = "More"
    let label: (Item) -> String
    @Namespace private var ns

    var body: some View {
        let visible = items.filter { !overflow.contains($0) }
        let hidden = items.filter { overflow.contains($0) }
        FlowLayout(spacing: 6) {
            ForEach(visible, id: \.self) { item in
                Button { selection = item } label: { chip(label(item), selected: item == selection) }
                    .buttonStyle(.plain)
            }
            if !hidden.isEmpty {
                let picked = hidden.first { $0 == selection }
                Menu {
                    ForEach(hidden, id: \.self) { item in Button(label(item)) { selection = item } }
                } label: {
                    chip((picked.map(label) ?? overflowTitle) + " ▾", selected: picked != nil)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .animation(.snappy(duration: 0.22), value: selection)
    }

    private func chip(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "chip", in: ns)
                } else {
                    Capsule().fill(.quaternary)
                }
            }
            .contentShape(Capsule())
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, h: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append((current, x - spacing, h))
                current = []; x = 0; h = 0
            }
            current.append(i)
            x += size.width + spacing
            h = max(h, size.height)
        }
        if !current.isEmpty { rows.append((current, x - spacing, h)) }
        return rows
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

extension OutputFormat {
    /// Formats our encoder writes EXIF/GPS into (WebP output never carries it).
    var keepsMetadata: Bool { self == .jpeg || self == .heic || self == .tiff || self == .png }
}
