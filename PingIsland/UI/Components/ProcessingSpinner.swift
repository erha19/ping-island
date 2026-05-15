//
//  ProcessingSpinner.swift
//  PingIsland
//
//  Animated symbol spinner for processing state
//

import SwiftUI

struct ProcessingSpinner: View {
    let color: Color
    let date: Date?
    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    init(color: Color = Color(red: 0.85, green: 0.47, blue: 0.34), date: Date? = nil) {
        self.color = color
        self.date = date
    }

    var body: some View {
        if energyGovernor.policy.animationLevel == .staticFrames {
            spinnerText(phase: 0)
        } else if let date {
            spinnerText(phase: spinnerPhase(for: date))
        } else {
            TimelineView(.periodic(from: .now, by: spinnerInterval)) { context in
                spinnerText(phase: spinnerPhase(for: context.date))
            }
        }
    }

    private var spinnerInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            0.15
        case .reduced:
            0.375
        case .staticFrames:
            0.15
        }
    }

    private func spinnerPhase(for date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate / spinnerInterval) % symbols.count
    }

    private func spinnerText(phase: Int) -> some View {
        Text(symbols[phase % symbols.count])
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
            .frame(width: 12, alignment: .center)
    }
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
