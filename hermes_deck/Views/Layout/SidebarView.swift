import SwiftUI
import AppKit

struct SidebarView: View {
    @Bindable var store: ChatStore
    @Binding var searchText: String
    @Binding var selectedDestination: SidebarDestination
    /// Owned by ContentView so the popover + its dismiss overlay can render at the
    /// window's top level (closing on a click anywhere, not just inside the sidebar).
    @Binding var showProfileMenu: Bool

    /// A non-resizable, fixed-size template image from the asset catalog. Menu
    /// labels don't honor a resizable image's frame (it balloons to the source
    /// size), so we pin the size on the NSImage itself instead.
    static func fixedTemplateImage(_ name: String, size: CGFloat) -> Image {
        if let base = NSImage(named: name), let copy = base.copy() as? NSImage {
            copy.size = NSSize(width: size, height: size)
            copy.isTemplate = true
            return Image(nsImage: copy)
        }
        return Image(systemName: "person.crop.circle")
    }

    var body: some View {
        ZStack {
            SidebarGlassBackground()

            VStack(alignment: .leading, spacing: 2) {
                Button {
                    selectedDestination = .chat
                    store.createThread()
                } label: {
                    SidebarActionRow(title: "New Chat", assetImage: "chat")
                }
                .buttonStyle(.plain)

                Button {
                    selectedDestination = .sessions
                    Task {
                        await store.loadSessions()
                    }
                } label: {
                    SidebarActionRow(title: "Sessions", assetImage: "chats", isSelected: selectedDestination == .sessions)
                }
                .buttonStyle(.plain)

                Button {
                    selectedDestination = .tools
                    Task {
                        await store.loadInstalledTools()
                    }
                } label: {
                    SidebarActionRow(title: "Tools", assetImage: "tools", isSelected: selectedDestination == .tools)
                }
                .buttonStyle(.plain)
                Button {
                    selectedDestination = .skills
                    Task {
                        await store.loadInstalledSkills()
                    }
                } label: {
                    SidebarActionRow(title: "Skills", assetImage: "skills", isSelected: selectedDestination == .skills)
                }
                .buttonStyle(.plain)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text("History")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                            .padding(.top, 4)

                        ForEach(store.historySessions) { session in
                            Button {
                                selectedDestination = .chat
                                Task { await store.loadSessionIntoChat(id: session.id) }
                            } label: {
                                SessionHistoryRow(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color.clear)
                .padding(.top, 10)

                // Profile picker only makes sense with more than one profile to
                // switch between; hide it entirely for single-profile setups.
                if store.availableProfiles.count > 1 {
                    Divider()
                    Button {
                        withAnimation(.smooth(duration: 0.15)) { showProfileMenu.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Self.fixedTemplateImage("robot", size: 17)
                                .foregroundStyle(.secondary)
                            Text(store.selectedProfile.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background(
                            showProfileMenu ? Color.primary.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .opacity(store.isResponding ? 0.4 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isResponding)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .navigationSplitViewColumnWidth(300)
        .task {
            await store.loadProfileMainModels()
            await store.loadHistorySessions()
        }
        .onChange(of: store.selectedProfile.id) { _, _ in
            Task { await store.loadHistorySessions() }
        }
        .onChange(of: showProfileMenu) { _, isOpen in
            guard isOpen else { return }
            Task { await store.loadProfileMainModels() }
            Task { await store.refreshAllGatewayStatuses() }
        }
    }
}

/// Upward profile popover: two-line rows (name over its configured main model),
/// background matched to the sidebar.
struct ProfileMenuList: View {
    @Bindable var store: ChatStore
    @Binding var isPresented: Bool
    var onSelect: (HermesProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.availableProfiles) { profile in
                let isSelected = profile.id == store.selectedProfile.id
                let isRunning = store.profileGatewayRunning[profile.id] ?? false
                Button {
                    onSelect(profile)
                    isPresented = false
                } label: {
                    HStack(spacing: 10) {
                        SidebarView.fixedTemplateImage("robot", size: 16)
                            .foregroundStyle(isSelected ? Color.primary : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(isSelected ? Color.primary : .secondary)
                                .lineLimit(1)
                            Text(store.profileMainModels[profile.id] ?? "—")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isRunning ? Color.green : Color.secondary)
                                    .frame(width: 5, height: 5)
                                Text(isRunning ? "Gateway Running" : "Gateway Stopped")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 12)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(isSelected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 8)
    }
}
