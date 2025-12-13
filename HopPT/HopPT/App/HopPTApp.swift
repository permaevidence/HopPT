import SwiftUI
import CoreData
import Combine
import MarkdownUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import Vision
import PDFKit
import UIKit
import CoreTransferable
import AVFoundation
import NaturalLanguage
import Security


@main
struct localChatApp: App {
    let persistenceController = PersistenceController.shared

    @StateObject private var settings = AppSettings()
    @StateObject private var chatVM: ChatViewModel

    init() {
        let ctx = PersistenceController.shared.container.viewContext
        let s   = AppSettings()
        _chatVM   = StateObject(wrappedValue: ChatViewModel(context: ctx, settings: s))
        _settings = StateObject(wrappedValue: s)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: chatVM)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(settings)
                .preferredColorScheme(.light)
        }
    }
}
