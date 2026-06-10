import SwiftUI

/// Right-sidebar settings panel: app appearance and the speech-recognition
/// dictation language. Both persist via `@AppStorage`, so changes take effect
/// app-wide without threading bindings through the view tree.
struct SettingsPanelView: View {
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(SpeechLanguageSettings.localeIdentifierKey)
    private var speechLocaleIdentifier = ""
    @State private var runtimeInfo: HermesRuntimeInfo?
    @State private var didLoadRuntimeInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(spacing: 8) {
                Image("Hermes")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
                Text("Hermes \(versionText)")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 32)

            settingGroup("Appearance") {
                Picker("Theme", selection: $appThemeRaw) {
                    Text("System").tag(AppTheme.system.rawValue)
                    Text("Light").tag(AppTheme.light.rawValue)
                    Text("Dark").tag(AppTheme.dark.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            settingGroup("Dictation Language") {
                Picker("Language", selection: $speechLocaleIdentifier) {
                    Text("Follow System").tag("")
                    ForEach(SpeechLanguageSettings.supportedLocaleIdentifiers, id: \.self) { identifier in
                        Text(SpeechLanguageSettings.displayName(for: identifier)).lineLimit(1).tag(identifier)
                    }
                }
                .labelsHidden()
            }

            Spacer()

            Text("\(appName) · \(appVersionText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            runtimeInfo = await HermesRuntimeInfoService.load()
            didLoadRuntimeInfo = true
        }
    }

    private var versionText: String {
        if let runtimeInfo { return runtimeInfo.version }
        return didLoadRuntimeInfo ? "Not installed" : "Checking…"
    }

    private let appName = "Hermes Deck"

    private var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "v\(short)"
    }

    @ViewBuilder
    private func settingGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 12)
    }
}
