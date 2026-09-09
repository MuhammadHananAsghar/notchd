// GuardCard.swift
// The guard section of the settings window: a switch, and the rules as an
// editable list. Each rule is a subject, a glob, an action, and a note. The
// card says plainly what guard mode is not: rules the user wrote, applied to
// hook-recorded calls only, never protection Notchd promises.

import SwiftUI

/// Edits the guard policy.
@MainActor
final class GuardModel: ObservableObject {
    @Published var document: GuardDocument {
        didSet { save() }
    }
    @Published private(set) var lastError: String?

    let policy: GuardPolicy

    /// Creates a model over a policy.
    /// - Parameter policy: The rules and their file.
    init(policy: GuardPolicy) {
        self.policy = policy
        document = policy.current
    }

    /// Turns guard mode on, seeding the suggested rules when there are none.
    func enable() {
        var updated = document
        updated.enabled = true
        if updated.rules.isEmpty { updated.rules = GuardRule.suggested }
        document = updated
    }

    /// Turns guard mode off, keeping the rules.
    func disable() {
        var updated = document
        updated.enabled = false
        document = updated
    }

    /// Adds an empty rule to edit.
    func addRule() {
        var updated = document
        updated.rules.append(GuardRule(subject: .command, pattern: "", action: .ask))
        document = updated
    }

    /// Removes a rule.
    /// - Parameter id: The rule's id.
    func remove(_ id: UUID) {
        var updated = document
        updated.rules.removeAll { $0.id == id }
        document = updated
    }

    /// A binding to one rule, for the row editor.
    /// - Parameter id: The rule's id.
    /// - Returns: A binding that writes through to the document.
    func binding(for id: UUID) -> Binding<GuardRule> {
        Binding(
            get: { self.document.rules.first { $0.id == id } ?? GuardRule(subject: .command, pattern: "", action: .ask) },
            set: { rule in
                var updated = self.document
                if let index = updated.rules.firstIndex(where: { $0.id == id }) { updated.rules[index] = rule }
                self.document = updated
            }
        )
    }

    /// Writes the document, keeping any error for the view.
    private func save() {
        do {
            try policy.update(document)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }
}

/// The guard card.
struct GuardCard: View {
    @ObservedObject var model: GuardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Guard").font(Typography.heading)
                Spacer()
                Toggle("Guard mode", isOn: enabled).labelsHidden()
            }
            Text("Rules you write, checked before a hook-recorded tool call runs. Deny refuses the call with the reason; Ask hands it to the agent's own permission prompt. Codex cannot be guarded, because Notchd learns of its calls from the transcript after they run. This is not a sandbox: it applies only to what agents declare, and only to the rules below.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            if model.document.enabled {
                rules
            }
            if let error = model.lastError {
                Text(error).font(Typography.caption).foregroundStyle(Palette.attention)
            }
        }
        .padding(16)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
    }

    /// The switch, seeding rules on first enable.
    private var enabled: Binding<Bool> {
        Binding(get: { model.document.enabled }, set: { on in on ? model.enable() : model.disable() })
    }

    /// The editable rule list.
    private var rules: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.document.rules) { rule in
                GuardRuleRow(rule: model.binding(for: rule.id)) { model.remove(rule.id) }
            }
            HStack {
                Button("Add rule") { model.addRule() }.controlSize(.small)
                Spacer()
                Text("Globs: * within a path segment, ** across segments. Path rules match whole paths; command rules match anywhere in the command.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

/// One rule's editor.
struct GuardRuleRow: View {
    @Binding var rule: GuardRule
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $rule.subject) {
                ForEach(GuardSubject.allCases) { subject in Text(subject.title).tag(subject) }
            }
            .labelsHidden()
            .frame(width: 100)
            TextField("Pattern", text: $rule.pattern).font(Typography.mono).textFieldStyle(.roundedBorder)
            Picker("", selection: $rule.action) {
                ForEach(GuardAction.allCases) { action in Text(action.title).tag(action) }
            }
            .labelsHidden()
            .frame(width: 80)
            TextField("Note", text: $rule.note).textFieldStyle(.roundedBorder).frame(width: 150)
            Button(role: .destructive, action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}
