import SwiftUI

struct SickDayBanner: View {
    let state: Home.StateModel

    var body: some View {
        if state.isSickDayModeActive {
            HStack(spacing: 10) {
                Image(systemName: "thermometer.medium")
                    .font(.title3)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sick Day Mode Active")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    if let hours = state.sickDayHoursActive, hours > 48 {
                        Text("Active for \(Int(hours))h — remember to turn off when recovered")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    } else {
                        Text("Expanded safety guardrails enabled")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                Spacer()

                Button {
                    state.toggleSickDayMode()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.red.opacity(0.85), Color.orange.opacity(0.75)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
