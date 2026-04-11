//
//  NotchViewController.swift
//  PingIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparency()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        guard hitTestRect().contains(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTransparency()
    }

    private func configureTransparency() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<AppLocalizedRootView<NotchView>>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = PassThroughHostingView(
            rootView: AppLocalizedRootView {
                NotchView(viewModel: viewModel)
            }
        )

        // Calculate the hit-test rect based on panel state
        hostingView.hitTestRect = { [weak self] in
            guard let self = self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window coordinates: origin at bottom-left, Y increases upward
            // The window is positioned at top of screen, so panel is at top of window
            let windowHeight = geometry.windowHeight

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                // Panel is centered horizontally, anchored to top
                let panelWidth = panelSize.width + 52  // Account for corner radius padding
                let panelHeight = panelSize.height
                let screenWidth = geometry.screenRect.width
                return CGRect(
                    x: (screenWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
            case .closed, .popping:
                let closedSize = vm.closedSize
                let screenWidth = geometry.screenRect.width
                // Add some padding for easier interaction
                return CGRect(
                    x: (screenWidth - closedSize.width) / 2 - 10,
                    y: windowHeight - closedSize.height - 5,
                    width: closedSize.width + 20,
                    height: closedSize.height + 10
                )
            }
        }

        self.view = hostingView
    }
}
