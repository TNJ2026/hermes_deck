import SwiftUI

struct SessionListView: View {
    @Bindable var store: ChatStore
    @Binding var selectedDestination: SidebarDestination
    @State private var sessionPendingDeletion: HermesSessionListItem?
    @State private var isAtBottom = false
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var isRefreshHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Sessions")
                    .font(.title2.weight(.semibold))

                Spacer()

                 Button {
                    Task {
                        await store.loadSessions()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(6)
                        .background(isRefreshHovered ? Color.primary.opacity(0.08) : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isRefreshHovered = hovering
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search sessions...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            Divider()

            Group {
                switch store.sessionListState {
                case .idle, .loading:
                    ProgressView("Loading sessions...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let sessions):
                    if sessions.isEmpty {
                        ContentUnavailableView("No Sessions", systemImage: "clock.badge.questionmark")
                    } else {
                        GeometryReader { proxy in
                            ZStack(alignment: .bottom) {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 18) {
                                        ForEach(SessionDateGrouper.groups(for: sessions)) { group in
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(group.title)
                                                    .font(.callout.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 4)

                                                LazyVStack(alignment: .leading, spacing: 8) {
                                                    ForEach(group.sessions) { session in
                                                        SessionRow(session: session) {
                                                            selectedDestination = .chat
                                                            Task {
                                                                await store.loadSessionIntoChat(id: session.id)
                                                            }
                                                        } onDelete: {
                                                            sessionPendingDeletion = session
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        if store.canLoadMoreSessions {
                                            Color.clear
                                                .frame(height: 1)
                                                .onAppear {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        isAtBottom = true
                                                    }
                                                }
                                                .onDisappear {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        isAtBottom = false
                                                    }
                                                }
                                        }
                                    }
                                    .padding(24)
                                }

                                if store.canLoadMoreSessions && isAtBottom {
                                    SessionLoadMoreButton(store: store)
                                        .padding(.bottom, 16)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                        }
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Failed to Load Sessions", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") {
                            Task {
                                await store.loadSessions()
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            if case .idle = store.sessionListState {
                await store.loadSessions()
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    store.sessionSearchQuery = newValue
                    await store.loadSessions()
                } catch {}
            }
        }
        .onChange(of: store.selectedProfile.id) { _, _ in
            searchTask?.cancel()
            searchText = ""
            store.sessionSearchQuery = ""
            Task { await store.loadSessions() }
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                guard let sessionPendingDeletion else { return }
                let sessionID = sessionPendingDeletion.id
                self.sessionPendingDeletion = nil

                Task {
                    await store.deleteSession(id: sessionID)
                }
            }

            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            if let sessionPendingDeletion {
                Text("This will delete \"\(sessionPendingDeletion.title)\" and its messages from the local Hermes database.")
            }
        }
    }
}

struct SessionLoadMoreButton: View {
    @Bindable var store: ChatStore

    var body: some View {
        Button {
            Task {
                await store.loadMoreSessions()
            }
        } label: {
            HStack(spacing: 6) {
                if store.isLoadingMoreSessions {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                } else {
                    Image(systemName: "chevron.down")
                    Text("Load More")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.ultraThinMaterial)
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(store.isLoadingMoreSessions)
    }
}

struct SessionRow: View {
    let session: HermesSessionListItem
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if !session.source.isEmpty {
                        SessionMetadataPill(text: session.source, monospaced: true)
                    }

                    SessionMetadataPill(text: "\(session.messageCount) messages")
                }
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if !session.lastActive.isEmpty {
                    Text(session.lastActive)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

struct SessionMetadataPill: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? .caption.monospaced() : .caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

struct SidebarActionRow: View {
    let title: String
    var systemImage: String? = nil
    var assetImage: String? = nil
    var isSelected = false

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 22, height: 22)
                .foregroundStyle(isSelected ? Color.primary : .secondary)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 38)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                .padding(.horizontal, 12)
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let assetImage {
            Image(assetImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
        }
    }
}

struct SidebarGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(.primary.opacity(0.08))
                    .frame(width: 1)
            }
            .ignoresSafeArea()
    }
}

struct SessionHistoryRow: View {
    let session: HermesSessionListItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.title)
                .font(.callout)
                .fontWeight(.regular)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !session.lastActive.isEmpty {
                Text(session.lastActive)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ThreadRow: View {
    let thread: ChatThread

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(thread.title)
                .font(.callout)
                .fontWeight(.regular)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(HistoryTimestampFormatter.displayText(for: thread.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
