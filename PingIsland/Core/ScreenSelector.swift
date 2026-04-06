//
//  ScreenSelector.swift
//  PingIsland
//
//  Manages screen selection state and persistence
//

import AppKit
import Combine
import Foundation

/// Strategy for selecting which screen to use
enum ScreenSelectionMode: String, Codable {
    case automatic       // Prefer built-in display, fall back to main
    case specificScreen  // User selected a specific screen
}

/// Persistent identifier for a screen
struct ScreenIdentifier: Codable, Equatable, Hashable {
    let displayID: CGDirectDisplayID?
    let localizedName: String

    /// Create identifier from NSScreen
    init(screen: NSScreen) {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            self.displayID = screenNumber
        } else {
            self.displayID = nil
        }
        self.localizedName = screen.localizedName
    }

    /// Check if this identifier matches a given screen
    func matches(_ screen: NSScreen) -> Bool {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return localizedName == screen.localizedName
        }
        // Primary match: displayID (most reliable when connected)
        if let savedID = displayID, savedID == screenNumber {
            return true
        }
        // Fallback: name match (for reconnected displays with new IDs)
        return localizedName == screen.localizedName
    }
}

@MainActor
class ScreenSelector: ObservableObject {
    static let shared = ScreenSelector()

    // MARK: - Published State
    @Published private(set) var availableScreens: [NSScreen] = []
    @Published private(set) var selectedScreen: NSScreen?
    @Published var selectionMode: ScreenSelectionMode = .automatic
    @Published var isPickerExpanded: Bool = false

    // MARK: - UserDefaults Keys
    private let modeKey = "screenSelectionMode"
    private let screenIdentifierKey = "selectedScreenIdentifier"

    // MARK: - Private State
    private var savedIdentifier: ScreenIdentifier?

    private init() {
        loadPreferences()
        refreshScreens()
    }

    // MARK: - Public API

    /// Refresh the available screens list
    func refreshScreens() {
        availableScreens = NSScreen.screens
        selectedScreen = resolveSelectedScreen()
    }

    /// Select a specific screen
    func selectScreen(_ screen: NSScreen) {
        selectionMode = .specificScreen
        savedIdentifier = ScreenIdentifier(screen: screen)
        selectedScreen = screen
        savePreferences()
    }

    /// Reset to automatic selection
    func selectAutomatic() {
        selectionMode = .automatic
        savedIdentifier = nil
        selectedScreen = resolveSelectedScreen()
        savePreferences()
    }

    /// Check if a screen is currently selected
    func isSelected(_ screen: NSScreen) -> Bool {
        guard let selected = selectedScreen else { return false }
        return screenID(of: screen) == screenID(of: selected)
    }

    /// Extra height needed when picker is expanded
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        // +1 for "Automatic" option
        return CGFloat(availableScreens.count + 1) * 40
    }

    // MARK: - Private Methods

    private func screenID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func resolveSelectedScreen() -> NSScreen? {
        switch selectionMode {
        case .automatic:
            return NSScreen.builtin ?? NSScreen.main

        case .specificScreen:
            // Try to find the saved screen
            if let identifier = savedIdentifier,
               let match = availableScreens.first(where: { identifier.matches($0) }) {
                return match
            }
            // Saved screen not found - fall back to automatic
            return NSScreen.builtin ?? NSScreen.main
        }
    }

    private func loadPreferences() {
        if let modeString = UserDefaults.standard.string(forKey: modeKey),
           let mode = ScreenSelectionMode(rawValue: modeString) {
            selectionMode = mode
        }

        if let data = UserDefaults.standard.data(forKey: screenIdentifierKey),
           let identifier = try? JSONDecoder().decode(ScreenIdentifier.self, from: data) {
            savedIdentifier = identifier
        }
    }

    private func savePreferences() {
        UserDefaults.standard.set(selectionMode.rawValue, forKey: modeKey)

        if let identifier = savedIdentifier,
           let data = try? JSONEncoder().encode(identifier) {
            UserDefaults.standard.set(data, forKey: screenIdentifierKey)
        } else {
            UserDefaults.standard.removeObject(forKey: screenIdentifierKey)
        }
    }
}
