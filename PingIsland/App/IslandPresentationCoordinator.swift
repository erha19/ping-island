import AppKit
import Combine

@MainActor
final class IslandPresentationCoordinator {
    private static let dockedWindowHeight: CGFloat = 750

    let sessionMonitor = SessionMonitor()
    let viewModel: NotchViewModel

    private var screen: NSScreen
    private var dockedWindowController: NotchWindowController?
    private var detachedWindowController: DetachedIslandWindowController?
    private var activeDetachmentPayload: IslandDetachmentPayload?
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen) {
        self.screen = screen
        self.viewModel = Self.makeViewModel(for: screen)
        bindViewModel()
        bindSettings()
        applySurfaceMode(AppSettings.surfaceMode, activationPolicy: .silent)
    }

    func updateScreen(_ screen: NSScreen) {
        self.screen = screen
        let geometry = Self.makeDockedScreenGeometry(for: screen)
        viewModel.updateScreenGeometry(
            deviceNotchRect: geometry.deviceNotchRect,
            screenRect: geometry.screenRect,
            windowHeight: geometry.windowHeight,
            hasPhysicalNotch: geometry.hasPhysicalNotch
        )
        applySurfaceMode(AppSettings.surfaceMode, performBootAnimation: false)
    }

    func beginDetachment(from request: IslandDetachmentRequest) {
        let resolvedContent = IslandDetachedContentResolver.resolve(
            status: viewModel.status,
            openReason: viewModel.openReason,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances
        )

        viewModel.beginDetachedPresentation(contentType: resolvedContent, playSound: true)

        let windowSize = DetachedIslandWindowController.windowSize(
            for: viewModel,
            sessionMonitor: sessionMonitor
        )
        let cursorWindowOffset = CGPoint(
            x: windowSize.width / 2,
            y: max(viewModel.closedHeight + 18, windowSize.height - 24)
        )

        let payload = IslandDetachmentPayload(
            contentType: resolvedContent,
            dragStartScreenLocation: request.dragStartScreenLocation,
            initialCursorScreenLocation: request.currentScreenLocation,
            cursorWindowOffset: cursorWindowOffset
        )
        activeDetachmentPayload = payload

        dockedWindowController?.window?.orderOut(nil)
        dockedWindowController?.close()
        dockedWindowController = nil

        let detachedWindowController = ensureDetachedWindowController()

        let origin = DetachedIslandWindowController.windowOrigin(
            for: payload.initialCursorScreenLocation,
            cursorWindowOffset: payload.cursorWindowOffset,
            windowSize: windowSize
        )
        detachedWindowController.present(at: origin)
        AppSettings.surfaceMode = .floatingPet
    }

    func updateDetachment(cursorLocation: CGPoint) {
        guard let payload = activeDetachmentPayload else { return }
        detachedWindowController?.updateDragPosition(
            cursorLocation: cursorLocation,
            cursorWindowOffset: payload.cursorWindowOffset
        )
    }

    func finishDetachment(cursorLocation: CGPoint?) {
        if let cursorLocation {
            updateDetachment(cursorLocation: cursorLocation)
        }

        DispatchQueue.main.async { [weak self] in
            self?.detachedWindowController?.endWindowDrag()
            self?.persistCurrentFloatingPetAnchor()
        }
    }

    func applySurfaceMode(
        _ mode: IslandSurfaceMode,
        performBootAnimation: Bool = false,
        activationPolicy: IslandPresentationActivationPolicy = .interactive
    ) {
        switch mode {
        case .notch:
            showDockedIsland(performBootAnimation: performBootAnimation)
        case .floatingPet:
            presentFloatingPet(
                playSound: false,
                activationPolicy: activationPolicy
            )
        }
    }

    func redockDetached() {
        detachedWindowController?.dismiss()
        detachedWindowController = nil
        activeDetachmentPayload = nil

        AppSettings.surfaceMode = .notch
        viewModel.redockAfterDetached()
        recreateDockedWindow(performBootAnimation: false)
    }

    func invalidate() {
        cancellables.removeAll()
        activeDetachmentPayload = nil
        detachedWindowController?.dismiss()
        detachedWindowController = nil
        dockedWindowController?.window?.orderOut(nil)
        dockedWindowController?.close()
        dockedWindowController = nil
    }

    private func bindViewModel() {
        viewModel.onDetachmentRequested = { [weak self] request in
            self?.beginDetachment(from: request)
        }
        viewModel.onDetachmentUpdated = { [weak self] location in
            self?.updateDetachment(cursorLocation: location)
        }
        viewModel.onDetachmentFinished = { [weak self] location in
            self?.finishDetachment(cursorLocation: location)
        }
    }

    private func bindSettings() {
        AppSettings.shared.$surfaceMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.applySurfaceMode(mode)
            }
            .store(in: &cancellables)
    }

    private func showDockedIsland(performBootAnimation: Bool) {
        activeDetachmentPayload = nil

        if viewModel.presentationMode == .detached || detachedWindowController != nil {
            detachedWindowController?.dismiss()
            detachedWindowController = nil
            viewModel.redockAfterDetached()
        }

        recreateDockedWindow(performBootAnimation: performBootAnimation)
    }

    private func presentFloatingPet(
        playSound: Bool,
        activationPolicy: IslandPresentationActivationPolicy = .interactive
    ) {
        if viewModel.presentationMode == .detached, detachedWindowController != nil {
            return
        }

        dockedWindowController?.window?.orderOut(nil)
        dockedWindowController?.close()
        dockedWindowController = nil
        activeDetachmentPayload = nil

        let resolvedContent = IslandDetachedContentResolver.resolve(
            status: viewModel.status,
            openReason: viewModel.openReason,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances
        )

        viewModel.beginDetachedPresentation(
            contentType: resolvedContent,
            playSound: playSound
        )

        let detachedWindowController = ensureDetachedWindowController()
        let visibleFrame = screen.visibleFrame
        let activeWindowFrame = ActiveWindowFrameResolver.currentActiveWindowFrame()
        let petAnchor = DetachedIslandWindowController.petAnchor(
            from: AppSettings.floatingPetAnchor,
            in: visibleFrame,
            defaultWindowFrame: activeWindowFrame
        )
        detachedWindowController.present(
            atPetAnchor: petAnchor,
            activatesApplication: activationPolicy.activatesApplication,
            presentsAutomaticContent: activationPolicy.presentsAutomaticContent
        )
        detachedWindowController.activateInteraction()
    }

    private func ensureDetachedWindowController() -> DetachedIslandWindowController {
        if let detachedWindowController {
            return detachedWindowController
        }

        let detachedWindowController = DetachedIslandWindowController(
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            onClose: { [weak self] in
                AppSettings.surfaceMode = .notch
                self?.activeDetachmentPayload = nil
            },
            onPetAnchorChanged: { [weak self] petAnchor in
                self?.persistFloatingPetAnchor(petAnchor)
            }
        )
        detachedWindowController.onRedockRequested = { [weak self] in
            self?.redockDetached()
        }
        self.detachedWindowController = detachedWindowController
        return detachedWindowController
    }

    private func persistCurrentFloatingPetAnchor() {
        guard let petAnchor = detachedWindowController?.currentPetAnchor else { return }
        persistFloatingPetAnchor(petAnchor)
    }

    private func persistFloatingPetAnchor(_ petAnchor: CGPoint) {
        AppSettings.floatingPetAnchor = DetachedIslandWindowController.floatingPetAnchor(
            from: petAnchor,
            in: screen.visibleFrame
        )
    }

    private func recreateDockedWindow(performBootAnimation: Bool) {
        dockedWindowController?.window?.orderOut(nil)
        dockedWindowController?.close()

        let controller = NotchWindowController(
            screen: screen,
            viewModel: viewModel,
            sessionMonitor: sessionMonitor,
            performBootAnimation: performBootAnimation
        )
        dockedWindowController = controller
        controller.showWindow(nil)
    }

    private static func makeViewModel(for screen: NSScreen) -> NotchViewModel {
        let geometry = makeDockedScreenGeometry(for: screen)

        return NotchViewModel(
            deviceNotchRect: geometry.deviceNotchRect,
            screenRect: geometry.screenRect,
            windowHeight: geometry.windowHeight,
            hasPhysicalNotch: geometry.hasPhysicalNotch,
            notchModuleWidthProvider: { AppSettings.notchModuleWidth }
        )
    }

    private struct DockedScreenGeometry {
        let deviceNotchRect: CGRect
        let screenRect: CGRect
        let windowHeight: CGFloat
        let hasPhysicalNotch: Bool
    }

    private static func makeDockedScreenGeometry(for screen: NSScreen) -> DockedScreenGeometry {
        let screenFrame = screen.frame
        let notchSize = screen.notchSize
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        return DockedScreenGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: dockedWindowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )
    }
}
