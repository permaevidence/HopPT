import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct ModelPickerMenu: View {
    @EnvironmentObject var settings: AppSettings
    var onManage: () -> Void = {}

    private func title(for ep: EndpointConfig) -> String {
        if !ep.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ep.name }
        // fallback to host of apiBase
        if let host = URL(string: ep.apiBase)?.host { return host }
        return "Endpoint"
    }

    var body: some View {
        Menu {
            if settings.endpoints.isEmpty {
                Button("Manage…", action: onManage)
            } else {
                ForEach(settings.endpoints) { ep in
                    if !ep.selectedModels.isEmpty {
                        Menu(title(for: ep)) {
                            ForEach(ep.selectedModels, id: \.self) { m in
                                Button {
                                    settings.setActiveModel(m, on: ep.id)
                                } label: {
                                    HStack {
                                        Text(m).font(.system(.body, design: .monospaced))
                                        if settings.activeEndpointID == ep.id && settings.model == m {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Manage…", action: onManage)
            }
        } label: {
            if let _ = settings.activeEndpoint, !settings.model.isEmpty {
                Text(settings.model.truncatedWithDots(maxChars: 25))
                    .font(.headline)
                    .foregroundColor(.black)
                    .accessibilityLabel(settings.model) // keep full name for VoiceOver
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                    Text("Select model").font(.headline)
                }
                .foregroundColor(.black)
            }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 240)
            .accentColor(.black)  // Add this line to make the menu indicator black
        }
}
