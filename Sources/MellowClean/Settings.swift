import SwiftUI
import MellowCore

@MainActor
final class Preferences: ObservableObject {
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "appLanguage") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "system") ?? .system
    }

    func text(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }
    func text(_ message: Message) -> String { message.rendered(in: language) }
}

struct SettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(preferences.text("设置", "Settings"), systemImage: "gearshape")
                .font(.title2.weight(.semibold))
            Picker(preferences.text("界面语言", "App language"), selection: $preferences.language) {
                Text(preferences.text("跟随系统", "System default")).tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.chinese)
                Text("English").tag(AppLanguage.english)
            }
            Text(preferences.text("切换后立即生效，重启后仍保留你的选择。", "Changes apply immediately and are remembered next time you open the app."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28).frame(width: 410)
        .preferredColorScheme(.light)
    }
}

struct SettingsButton: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Label(preferences.text("设置", "Settings"), systemImage: "gearshape") }
        } else {
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { Label(preferences.text("设置", "Settings"), systemImage: "gearshape") }
        }
    }
}
