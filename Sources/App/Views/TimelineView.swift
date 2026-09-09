// TimelineView.swift
// The main window. A sidebar with the timeline, every session, and the
// unattributed lane; a detail pane that shows the lanes with their inspector,
// one session as a log, or the unattributed list. The revert sheet hangs off
// the whole window so it can open from either page.

import SwiftUI

/// The main window.
struct TimelineView: View {
    @ObservedObject var model: TimelineModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            switch model.page {
            case .timeline:
                TimelinePage(model: model)
            case .session:
                if let session = model.selectedSession {
                    SessionDetailView(session: session, events: model.events, changesByEvent: model.changesByEvent)
                } else {
                    TimelinePage(model: model)
                }
            case .unattributed:
                UnattributedView(changes: model.unattributed)
            }
        }
        .background(Palette.surface)
        .sheet(item: $model.pendingRevert) { pending in
            RevertSheet(model: model, plan: pending.plan)
        }
        .onAppear { model.refresh() }
    }

    /// The timeline entry, one row per session, and the unattributed lane.
    private var sidebar: some View {
        List(selection: $model.page) {
            Label("Timeline", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(Typography.body)
                .tag(Page.timeline)
            Section("Sessions") {
                ForEach(model.sessions.filter { $0.vendor != "notchd" }) { session in
                    SessionRowView(session: session).tag(Page.session(session.id))
                }
            }
            if !model.unattributed.isEmpty {
                Section("Other") {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Palette.separator).frame(width: 8, height: 8).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not from any known agent").font(Typography.body)
                            Text("\(model.unattributed.count) changes").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(Page.unattributed)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The lanes with their range control and inspector.
struct TimelinePage: View {
    @ObservedObject var model: TimelineModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.lanes.isEmpty {
                emptyLanes
            } else {
                lanes
            }
            Divider()
            InspectorView(model: model)
        }
        .background(Palette.panel)
    }

    /// The lane view at exactly the height its lanes need, scrolling once
    /// there are more lanes than fit the cap.
    private var lanes: some View {
        let needed = LaneLayout.height(forLanes: model.lanes.count)
        let shown = min(needed, LaneLayout.maximumHeight)
        return Group {
            if needed > shown {
                ScrollView(.vertical) {
                    LaneView(model: model).frame(height: needed)
                }
            } else {
                LaneView(model: model)
            }
        }
        .frame(height: shown)
    }

    /// Range picker, legend, and the hover readout.
    private var header: some View {
        HStack(spacing: 14) {
            Picker("Range", selection: $model.range) {
                ForEach(TimeRange.allCases) { range in Text(range.title).tag(range) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            legend
            Spacer()
            if let hover = model.hover {
                Text("\(ChangeCopy.mark(for: hover.change.kind)) \(hover.change.path)")
                    .font(Typography.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Palette.textSecondary)
            } else if model.selection == nil {
                Text("Drag across a lane to select a span")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The three change colours.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(ChangeKind.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(Palette.color(for: kind)).frame(width: 3, height: 12)
                    Text(ChangeCopy.word(for: kind)).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    /// Shown when nothing happened in the range.
    private var emptyLanes: some View {
        VStack(spacing: 8) {
            Text("No changes in this range").font(Typography.heading)
            Text(model.hasAnySessions
                 ? "Widen the range, or wait for an agent to change something."
                 : "Set up an agent from the menu bar. Every file it changes will appear here.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}
