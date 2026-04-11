import AppKit
import SwiftUI

struct ReleaseNotesWindowView: View {
    let notes: UpdateReleaseNotes
    let onClose: () -> Void

    @Environment(\.locale) private var locale
    @State private var expandedSectionIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 24) {
                appIcon
                versionBadge
                releaseNotesContent
            }
            .padding(.top, 40)
            .padding(.horizontal, 34)
            .padding(.bottom, 28)

            Divider()
                .overlay(Color.white.opacity(0.08))

            Button(action: onClose) {
                Text("好")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
            .preferredColorScheme(.dark)
            .onAppear {
                if expandedSectionIDs.isEmpty {
                    expandedSectionIDs = Set(displayedSections.map(\.id))
                }
            }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 112, height: 112)
            .shadow(color: .black.opacity(0.24), radius: 18, y: 10)
    }

    private var versionBadge: some View {
        HStack(spacing: 14) {
            Text(notes.currentVersion)
                .foregroundColor(.white.opacity(0.6))

            Image(systemName: "arrow.right")
                .foregroundColor(.white.opacity(0.35))

            Text(notes.targetVersion)
                .foregroundColor(.white.opacity(0.92))

            Text("🎉")
        }
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .padding(.horizontal, 24)
        .frame(height: 58)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var releaseNotesContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(displayedSections.isEmpty ? [fallbackSection] : displayedSections) { section in
                    ReleaseNotesSectionCard(
                        section: section,
                        isExpanded: expandedSectionIDs.contains(section.id),
                        toggle: { toggleSection(section.id) }
                    )
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: 430)
    }

    private var displayedSections: [UpdateReleaseNotesSection] {
        notes.sections(locale: locale)
    }

    private var fallbackSection: UpdateReleaseNotesSection {
        UpdateReleaseNotesSection(
            id: "fallback",
            title: AppLocalization.string("更新内容"),
            markdown: notes.localizedMarkdown(locale: locale)
        )
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.20, green: 0.21, blue: 0.24),
                Color(red: 0.15, green: 0.15, blue: 0.17)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.black.opacity(0.18))
        )
    }

    private func toggleSection(_ id: String) {
        if expandedSectionIDs.contains(id) {
            expandedSectionIDs.remove(id)
        } else {
            expandedSectionIDs.insert(id)
        }
    }
}

private struct ReleaseNotesSectionCard: View {
    let section: UpdateReleaseNotesSection
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    Text(section.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white.opacity(0.92))

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .padding(.horizontal, 24)

                MarkdownText(section.markdown, color: .white.opacity(0.82), fontSize: 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }
}
