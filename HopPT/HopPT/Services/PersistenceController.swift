import Foundation
import CoreData

class PersistenceController {
    static let shared = PersistenceController()
    let container: NSPersistentContainer

    init() {
        // Create the model programmatically
        let model = NSManagedObjectModel()

        // Create both entities first
        let messageEntity = NSEntityDescription()
        messageEntity.name = "Message"
        messageEntity.managedObjectClassName = "Message"

        let conversationEntity = NSEntityDescription()
        conversationEntity.name = "Conversation"
        conversationEntity.managedObjectClassName = "Conversation"

        // Message attributes
        let messageIdAttribute = NSAttributeDescription()
        messageIdAttribute.name = "id"
        messageIdAttribute.attributeType = .UUIDAttributeType
        messageIdAttribute.isOptional = false

        let contentAttribute = NSAttributeDescription()
        contentAttribute.name = "content"
        contentAttribute.attributeType = .stringAttributeType
        contentAttribute.isOptional = false

        let isUserAttribute = NSAttributeDescription()
        isUserAttribute.name = "isUser"
        isUserAttribute.attributeType = .booleanAttributeType
        isUserAttribute.isOptional = false

        let timestampAttribute = NSAttributeDescription()
        timestampAttribute.name = "timestamp"
        timestampAttribute.attributeType = .dateAttributeType
        timestampAttribute.isOptional = false

        let modelNameAttribute = NSAttributeDescription()
        modelNameAttribute.name = "modelName"
        modelNameAttribute.attributeType = .stringAttributeType
        modelNameAttribute.isOptional = true

        // Conversation attributes
        let convIdAttribute = NSAttributeDescription()
        convIdAttribute.name = "id"
        convIdAttribute.attributeType = .UUIDAttributeType
        convIdAttribute.isOptional = false

        let titleAttribute = NSAttributeDescription()
        titleAttribute.name = "title"
        titleAttribute.attributeType = .stringAttributeType
        titleAttribute.isOptional = false

        let createdAtAttribute = NSAttributeDescription()
        createdAtAttribute.name = "createdAt"
        createdAtAttribute.attributeType = .dateAttributeType
        createdAtAttribute.isOptional = false

        let updatedAtAttribute = NSAttributeDescription()
        updatedAtAttribute.name = "updatedAt"
        updatedAtAttribute.attributeType = .dateAttributeType
        updatedAtAttribute.isOptional = true

        // Create relationships after entities are defined
        let conversationRelation = NSRelationshipDescription()
        conversationRelation.name = "conversation"
        conversationRelation.destinationEntity = conversationEntity
        conversationRelation.maxCount = 1
        conversationRelation.deleteRule = .nullifyDeleteRule
        conversationRelation.isOptional = true

        let messagesRelation = NSRelationshipDescription()
        messagesRelation.name = "messages"
        messagesRelation.destinationEntity = messageEntity
        messagesRelation.maxCount = 0
        messagesRelation.deleteRule = .cascadeDeleteRule
        messagesRelation.isOptional = true
        messagesRelation.isOrdered = true

        // Set inverse relationships
        conversationRelation.inverseRelationship = messagesRelation
        messagesRelation.inverseRelationship = conversationRelation

        // Add properties to entities
        messageEntity.properties = [messageIdAttribute, contentAttribute, isUserAttribute, timestampAttribute, modelNameAttribute, conversationRelation]
        conversationEntity.properties = [
          convIdAttribute, titleAttribute, createdAtAttribute, updatedAtAttribute, messagesRelation
        ]

        // Add entities to model
        model.entities = [messageEntity, conversationEntity]

        // Initialize container with the custom model
        container = NSPersistentContainer(name: "ChatModel", managedObjectModel: model)

        if let desc = container.persistentStoreDescriptions.first {
            desc.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            desc.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data failed to load: \(error.localizedDescription)")
            }
        }
    }
}
