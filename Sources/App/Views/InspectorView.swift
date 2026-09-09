// InspectorView.swift
// The bottom half of the timeline page. With nothing selected it lists the
// files most changed in the range. With a selection it lists the files, the
// diff of the one chosen, the tool calls that caused them, and the Revert
// button. The revert sheet is the second step: per-file ticks, the shell
// commands whose non-file effects cannot be undone, confirm, then the result.

import SwiftUI

/// The inspector.
struct InspectorView: View {
    @ObservedObject var model: TimelineModel

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 260, idealWidth: 340)
            detail
                .frame(minWidth: 300)
        }
    }

    /// The files in the selection, or the most changed files in the range.
    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selection == nil ? "Most changed in range" : "\(model.files.count) files in selection")
                    .font(Typography.heading)
                Spacer()
                if model.selection != nil {
                    Button("Clear") { model.selection = nil }.controlSize(.small)
                    Button("Revert…") { model.prepareRevert() }
                        .controlSize(.small)
                        .disabled(model.files.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            let files = model.selection == nil ? FileSummary.summaries(model.changesInRange) : model.files
            if files.isEmpty {
                Text("Nothing here").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files, selection: fileSelection) { file in
                    FileSummaryRow(file: file).tag(file.path)
                }
                .listStyle(.plain)
            }
            if let error = model.revertError {
                Text(error).font(Typography.caption).foregroundStyle(Palette.attention).padding(8)
            }
        }
        .background(Palette.panel)
    }

    /// Binds the list selection to the model's selected file.
    private var fileSelection: Binding<String?> {
        Binding(
            get: { model.selectedFile?.path },
            set: { path in
                let files = model.selection == nil ? FileSummary.summaries(model.changesInRange) : model.files
                model.selectedFile = files.first { $0.path == path }
            }
        )
    }

    /// The diff of the chosen file and the calls that caused the selection.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let file = model.selectedFile {
                DiffView(file: file, diff: model.diff)
            } else {
                Text("Select a file to see what changed")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.causes.isEmpty {
                Divider()
                causes
            }
        }
        .background(Palette.surface)
    }

    /// The tool calls behind the selected changes.
    private var causes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Caused by").font(Typography.heading)
            ForEach(model.causes.prefix(8)) { event in
                HStack(spacing: 8) {
                    Text(event.ts.formatted(date: .omitted, time: .standard)).font(Typography.mono).foregroundStyle(Palette.textSecondary)
                    Text(EventCopy.title(for: event)).font(Typography.caption)
                    if let detail = EventCopy.detail(for: event) {
                        Text(detail).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if model.causes.count > 8 {
                Text("and \(model.causes.count - 8) more").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One file in the inspector list.
struct FileSummaryRow: View {
    let file: FileSummary

    var body: some View {
        HStack(spacing: 8) {
            Text(ChangeCopy.mark(for: file.kind))
                .font(Typography.mono)
                .foregroundStyle(Palette.color(for: file.kind))
                .frame(width: 10)
            Text(file.path).font(Typography.mono).lineLimit(1).truncationMode(.middle)
            Spacer()
            if file.changeCount > 1 {
                Text("×\(file.changeCount)").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
            if !file.attributed {
                Text("unattributed").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.vertical, 1)
    }
}

/// The diff of one file.
struct DiffView: View {
    let file: FileSummary
    let diff: LineDiffResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(ChangeCopy.word(for: file.kind)).font(Typography.heading).foregroundStyle(Palette.color(for: file.kind))
                Text(file.path).font(Typography.mono).lineLimit(1).truncationMode(.middle)
                Spacer()
                sizes
            }
            .padding(12)
            Divider()
            content
        }
        .background(Palette.surface)
    }

    /// Byte sizes before and after.
    private var sizes: some View {
        Text("\(file.before?.size ?? 0) → \(file.after?.size ?? 0) bytes")
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
    }

    /// The rendered lines, or the reason there are none.
    @ViewBuilder
    private var content: some View {
        switch diff {
        case nil:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .identical:
            note("Contents are identical; only the mode or link target changed.")
        case .binary(let before, let after):
            note("Binary content, \(before) bytes before and \(after) after.")
        case .tooLarge(let before, let after):
            note("Too large to diff here: \(before) lines before, \(after) after.")
        case .lines(let lines):
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(line: line)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                }
            }
        }
    }

    /// A one-line explanation in place of a diff.
    private func note(_ text: String) -> some View {
        Text(text).font(Typography.body).foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One line of a diff.
struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(prefix).frame(width: 18, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
        }
        .font(Typography.mono)
        .foregroundStyle(line.kind == .fold ? Palette.textSecondary : Palette.textPrimary)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var prefix: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        case .fold: return "…"
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Palette.create.opacity(0.14)
        case .removed: return Palette.delete.opacity(0.14)
        case .context, .fold: return .clear
        }
    }
}

/// The two-step revert: tick files, read what will not be undone, confirm.
struct RevertSheet: View {
    @ObservedObject var model: TimelineModel
    let plan: RevertPlan
    @State private var ticked: Set<String>

    /// Starts with every possible target ticked.
    init(model: TimelineModel, plan: RevertPlan) {
        self.model = model
        self.plan = plan
        _ticked = State(initialValue: Set(plan.possibleTargets.map(\.path)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = model.revertResult {
                outcome(result)
            } else {
                proposal
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
        .background(Palette.surface)
    }

    /// What will happen, before confirmation.
    private var proposal: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revert \(ticked.count) of \(plan.targets.count) paths").font(Typography.title)
            Text("Each ticked path returns to the state it had at the start of the selection. The current state is checkpointed first, so this can be undone.")
                .font(Typography.body).foregroundStyle(Palette.textSecondary)
            List(plan.targets, id: \.path) { target in
                RevertTargetRow(target: target, ticked: binding(for: target))
            }
            .listStyle(.bordered)
            if !plan.commands.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.commands.count == 1
                         ? "1 shell command ran in this span. Its files are restored above; anything else it did, such as a network request or a database write, is not undone."
                         : "\(plan.commands.count) shell commands ran in this span. Their files are restored above; anything else they did, such as a network request or a database write, is not undone.")
                        .font(Typography.caption).foregroundStyle(Palette.attention)
                    ForEach(plan.commands.prefix(4), id: \.self) { command in
                        Text(command).font(Typography.mono).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.dismissRevert() }.keyboardShortcut(.cancelAction)
                Button("Restore \(ticked.count) paths") { model.applyRevert(plan, keeping: ticked) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticked.isEmpty)
            }
        }
    }

    /// What happened, after confirmation.
    private func outcome(_ result: RevertResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.outcome == .complete ? "Complete" : "Partial")
                .font(Typography.title)
                .foregroundStyle(result.outcome == .complete ? Palette.create : Palette.attention)
            Text(result.outcome == .complete
                 ? "Every one of the \(result.restored.count) paths was restored and verified bit for bit."
                 : "\(result.restored.count) paths were restored and verified. \(result.failed.count) could not be:")
                .font(Typography.body)
            if !result.failed.isEmpty {
                List(result.failed, id: \.path) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.path).font(Typography.mono).lineLimit(1).truncationMode(.middle)
                        Text(failure.reason).font(Typography.caption).foregroundStyle(Palette.attention)
                    }
                }
                .listStyle(.bordered)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { model.dismissRevert() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    /// A tick binding for one target; impossible targets stay unticked.
    private func binding(for target: RevertTarget) -> Binding<Bool> {
        Binding(
            get: { ticked.contains(target.path) },
            set: { on in
                if case .impossible = target.action { return }
                if on { ticked.insert(target.path) } else { ticked.remove(target.path) }
            }
        )
    }
}

/// One path in the revert sheet.
struct RevertTargetRow: View {
    let target: RevertTarget
    @Binding var ticked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $ticked).labelsHidden().disabled(isImpossible)
            Text(target.path).font(Typography.mono).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(description).font(Typography.caption).foregroundStyle(isImpossible ? Palette.attention : Palette.textSecondary)
        }
    }

    private var isImpossible: Bool {
        if case .impossible = target.action { return true }
        return false
    }

    private var description: String {
        switch target.action {
        case .restore(let entry): return "restore \(entry.size) bytes"
        case .delete: return "remove"
        case .impossible(let reason): return reason
        }
    }
}
