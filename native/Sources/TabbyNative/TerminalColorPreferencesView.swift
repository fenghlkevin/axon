import SwiftUI
import AppKit

struct TerminalColorPreferencesView: View {
    @Binding var draft: Preferences
    let chinese: Bool
    var scrollToSection: ((String) -> Void)? = nil
    var commit: ((Preferences) throws -> Void)? = nil
    @State private var search = ""
    @State private var filter = TerminalThemeFilter.all
    @State private var editor: TerminalThemeEditorRequest?
    @State private var message = ""
    @State private var messageIsError = false
    @State private var deleting: TerminalTheme?
    private var current: TerminalTheme { TerminalTheme.selected(draft) }
    private var filtered: [TerminalTheme] { TerminalThemeLibrary.filtered(draft, search: search, filter: filter) }
    private func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text("Current scheme", "当前方案")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text(current.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if current.isCustom {
                        Text(text("Custom", "自定义")).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Palette.selected).clipShape(Capsule())
                    }
                    PreferencesActionButton(title: text("Edit colors…", "编辑配色…"), identifier: "axon-theme-edit-colors") { openEditor(saveAsNew: false) }.frame(width: 108, height: 32)
                    if current.isCustom {
                        PreferencesActionButton(title: text("Delete", "删除方案"), identifier: "axon-theme-delete", destructive: true) {
                            deleting = current
                        }.frame(width: chinese ? 76 : 64, height: 32)
                    }
                }
                schemePreview
                Text(text("Edit in a separate window. Built-in schemes are copied; your custom schemes can be updated or saved as a new copy.", "点击「编辑配色」打开独立窗口。内置方案另存为新方案；自定义方案可直接更新，也可另存为新方案。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            section {
                HStack {
                    Text(text("Scheme library", "配色方案库")).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    PreferencesActionButton(title: text("New scheme…", "新建方案…"), identifier: "axon-theme-create", prominent: true) { openEditor(saveAsNew: true) }.frame(width: chinese ? 104 : 116, height: 32)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField(text("Search schemes", "搜索配色方案"), text: $search).textFieldStyle(.plain).accessibilityIdentifier("axon-theme-search")
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(AxonSurfaceButtonStyle()).help(text("Clear search", "清空搜索")) }
                }.padding(10).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 6) {
                    ForEach(TerminalThemeFilter.allCases) { item in
                        ThemeFilterButton(title: item.title(chinese: chinese), selected: filter == item, identifier: "axon-theme-filter-" + item.rawValue) { filter = item }.frame(width: chinese ? 54 : 68, height: 30)
                    }
                    Spacer(minLength: 0)
                    Text("\(filtered.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                schemeGrid
                Text(commit == nil ? text("Select a card to preview. Save settings below to apply the selection and persist your scheme library.", "点击卡片预览。方案选择与方案库更改，点击设置底部「保存」后持久生效。") : text("Select a card to apply its colors automatically. Saving in the color editor keeps and applies your custom scheme immediately.", "点击卡片后自动应用所选方案。编辑窗口中保存方案后，立即保留并应用自定义配色。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !message.isEmpty {
                Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 12)).foregroundStyle(messageIsError ? Palette.danger : Palette.accent).fixedSize(horizontal: false, vertical: true)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }.appAlert(text("Delete custom scheme?", "删除自定义方案？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { theme in
            AppAlertButton(text("Cancel", "取消"), role: .cancel) { deleting = nil }
            AppAlertButton(text("Delete scheme", "删除方案"), role: .destructive) { remove(theme); deleting = nil }
        } message: { theme in
            Text(theme.name + text(" will be removed from your scheme library. The current terminal palette will return to Dracula Green.", " 将从配色方案库中移除；当前终端配色将恢复为 Dracula Green。"))
        }.sheet(item: $editor) { request in
            TerminalThemeEditor(request: request, chinese: chinese, persistsImmediately: commit != nil) { edited in
                let updated = try edited.saving(to: draft, chinese: chinese)
                try commit?(updated)
                draft = updated
                filter = .custom; search = ""; editor = nil; messageIsError = false
                message = commit == nil ? text("Scheme saved in the settings draft. Save settings below to keep it and apply it to open terminals.", "方案已保存到设置草稿。点击底部「保存」，即可保留方案并应用到已打开终端。") : text("Scheme saved and applied to open terminals.", "方案已保存，并已应用到打开的终端。")
            }
        }
    }
    private func remove(_ theme: TerminalTheme) {
        var updated = draft
        TerminalThemeLibrary.remove(theme.id, in: &updated)
        do {
            try commit?(updated); draft = updated; messageIsError = false
            message = commit == nil ? text("Scheme removed from the settings draft. Revert restores it before saving.", "已从设置草稿中删除方案；保存前可通过撤销更改恢复。") : text("Custom scheme deleted.", "自定义方案已删除。")
        } catch { message = error.localizedDescription; messageIsError = true }
    }
    private func openEditor(saveAsNew: Bool) {
        editor = TerminalThemeEditorRequest(preferences: draft, saveAsNew: saveAsNew, chinese: chinese)
    }
    private var schemeGrid: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "paintpalette").font(.system(size: 28)).foregroundStyle(Palette.muted)
                    Text(filter == .custom && search.isEmpty ? text("Create your first custom scheme", "创建你的第一个自定义方案") : text("No matching schemes", "没有匹配的配色方案")).font(.system(size: 13, weight: .semibold))
                    Text(filter == .custom && search.isEmpty ? text("Start with the current palette, edit its colors and give it a name.", "以当前配色为基础，调整颜色并命名保存。") : text("Try another filter or clear your search.", "请调整筛选条件或清空搜索。"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if filter == .custom && search.isEmpty {
                        PreferencesActionButton(title: text("New custom scheme…", "新建自定义方案…"), identifier: "axon-theme-empty-create", prominent: true) { openEditor(saveAsNew: true) }.frame(width: chinese ? 146 : 178, height: 34)
                    }
                }.frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 166), spacing: 12)], spacing: 12) {
                    ForEach(filtered) { theme in
                        TerminalThemeCardButton(theme: theme, selected: draft.terminalTheme == theme.id, chinese: chinese) {
                            draft = theme.applying(to: draft); message = ""; messageIsError = false
                        }.frame(height: 140)
                    }
                }.padding(2)
            }
        }
    }
    private var schemePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(text("Live preview", "实时预览")).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text(draft.fontName + " · " + TerminalFontSizeNativeEditor.display(draft.fontSize) + " pt")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            TerminalColorPreview(preferences: draft, identifier: "axon-theme-library-preview", chinese: chinese, style: .expanded)
        }
    }
    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

enum TerminalColorPreviewStyle: Equatable {
    case compact, expanded
}

struct TerminalColorPreview: View {
    let preferences: Preferences
    var identifier = "axon-theme-preview"
    var chinese = false
    var style = TerminalColorPreviewStyle.compact
    var body: some View {
        TerminalPreferencesPreview(preferences: preferences, sample: style == .expanded ? .paletteExtended : .palette, identifier: identifier, chinese: chinese)
            .frame(height: style == .expanded ? 236 : 124).padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(hex: preferences.background))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct TerminalColorField: View {
    let title: String
    @Binding var value: String
    let identifier: String
    var compact = false
    var explanation: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
            if !compact { Text(title).foregroundStyle(Palette.muted).frame(width: 68, alignment: .leading) }
            TextField("#RRGGBB", text: $value).appInput().font(.system(size: 11, design: .monospaced)).accessibilityLabel(title).accessibilityIdentifier(identifier)
            ColorPicker(title, selection: Binding(get: { Color(hex: value) }, set: { color in
                if let rgb = NSColor(color).usingColorSpace(.deviceRGB) { value = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())) }
            }), supportsOpacity: false).labelsHidden().frame(width: 28)
        }.frame(maxWidth: .infinity).overlay(alignment: .bottomLeading) { if !TerminalThemeLibrary.isHex(value) { Text("#RRGGBB").font(.system(size: 9)).foregroundStyle(.red).offset(y: 11) } }
        if let explanation { Text(explanation).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct ThemeFilterButton: NSViewRepresentable {
    let title: String
    let selected: Bool
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesRectNativeButton { PreferencesRectNativeButton() }
    func updateNSView(_ button: PreferencesRectNativeButton, context: Context) {
        button.title = title; button.selected = selected; button.prominent = selected; button.actionBlock = action; button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityLabel(title); button.setAccessibilityValue(selected ? "Selected" : ""); button.needsDisplay = true
    }
}
