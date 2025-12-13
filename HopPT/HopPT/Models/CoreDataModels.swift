import Foundation
import CoreData

@objc(Message)
class Message: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var content: String
    @NSManaged var isUser: Bool
    @NSManaged var timestamp: Date
    @NSManaged var conversation: Conversation?
    @NSManaged var modelName: String?
}

@objc(Conversation)
class Conversation: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date?
    @NSManaged var messages: NSOrderedSet?
}
