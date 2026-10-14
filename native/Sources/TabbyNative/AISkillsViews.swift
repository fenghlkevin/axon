import SwiftUI

struct AISkillsContextView: View {
    let items: [AISkills.Item]
    let loaded: [String]
    @EnvironmentObject private var store: AppStore
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.name + (loaded.contains(item.path) ? store.text(" · Loaded", " · 已加载") : ""), systemImage: loaded.contains(item.path) ? "checkmark.circle" : "doc.text")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                    Text(item.description).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Text(item.path).font(.system(size: 10)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(store.text("Metadata is available to the agent; instructions load only when selected. Scripts require existing execution checks.", "AI 可查看名称与描述，选用时才加载正文；脚本仍需执行检查。")).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text(store.text("Workflow skills · \(items.count)", "工作流技能 · \(items.count)")) }
            .font(.system(size: 12)).foregroundStyle(Palette.muted).accessibilityIdentifier("axon-ai-skills-context")
    }
}
