import SwiftUI

struct IslandOpenedContentView: View {
    let sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    let surface: IslandExpandedSurface
    let trigger: IslandExpandedTrigger
    let style: IslandOpenedPresentationStyle
    let activeCompletionNotification: SessionCompletionNotification?
    var highlightedSessionStableID: String? = nil
    var contentWidthOverride: CGFloat? = nil
    let onAttentionActionCompleted: () -> Void
    let onCompletionNotificationHoverChanged: (Bool) -> Void
    let onDismissCompletionNotification: () -> Void

    var body: some View {
        routeContent
        .frame(width: contentWidth)
        .onAppear {
            sessionMonitor.refreshUsageState()
        }
    }

    private var route: IslandExpandedRoute {
        IslandExpandedRouteResolver.resolve(
            surface: surface,
            trigger: trigger,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances,
            activeCompletionNotification: activeCompletionNotification
        )
    }

    private var hoverPreviewSessions: [SessionState] {
        IslandExpandedRouteResolver.activePreviewSessions(from: sessionMonitor.instances)
    }

    @ViewBuilder
    private var routeContent: some View {
        switch route {
        case .sessionList:
            SessionListView(
                sessionMonitor: sessionMonitor,
                viewModel: viewModel,
                enableKeyboardNavigation: surface == .docked,
                highlightedSessionStableID: highlightedSessionStableID
            )
        case .hoverDashboard:
            SessionHoverDashboardView(
                sessions: hoverPreviewSessions,
                sessionMonitor: sessionMonitor,
                density: surface == .floating ? .detachedCompact : .regular,
                onQuestionInteractionStateChanged: { viewModel.setInlineTextInputActive($0) }
            )
        case .attentionNotification(let session):
            SessionAttentionNotificationView(
                session: liveSession(for: session),
                sessionMonitor: sessionMonitor,
                density: surface == .floating ? .detachedCompact : .regular,
                onQuestionInteractionStateChanged: { viewModel.setInlineTextInputActive($0) },
                onActionCompleted: onAttentionActionCompleted
            )
        case .completionNotification(let notification):
            SessionCompletionNotificationView(
                notification: liveNotification(notification),
                presentationStyle: style == .detached ? .bubble : .panel,
                onHoverChanged: onCompletionNotificationHoverChanged,
                onDismiss: onDismissCompletionNotification
            )
        case .chat(let session):
            let liveSession = liveSession(for: session)

            if liveSession.provider == .claude || liveSession.provider == .kimi {
                ChatView(
                    sessionId: liveSession.sessionId,
                    initialSession: liveSession,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            } else {
                CodexSessionView(
                    session: liveSession,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            }
        }
    }

    private func liveSession(for session: SessionState) -> SessionState {
        sessionMonitor.instances.first(where: { $0.sessionId == session.sessionId }) ?? session
    }

    private func liveNotification(_ notification: SessionCompletionNotification) -> SessionCompletionNotification {
        guard let latestSession = sessionMonitor.instances.first(where: {
            $0.sessionId == notification.session.sessionId
        }) else {
            return notification
        }

        var updated = notification
        updated.session = latestSession
        return updated
    }

    private var contentWidth: CGFloat {
        if let contentWidthOverride {
            return contentWidthOverride
        }

        switch style {
        case .docked:
            return viewModel.openedSize.width - 24
        case .detached:
            return viewModel.detachedSize.width - 24
        }
    }
}
