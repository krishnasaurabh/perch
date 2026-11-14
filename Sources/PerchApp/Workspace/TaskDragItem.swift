import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let perchTask = UTType(exportedAs: "app.perch.task", conformingTo: .data)
    static let perchParkedThought = UTType(exportedAs: "app.perch.parked-thought", conformingTo: .data)
}

/// Typed local identities. Never resolve a drop by title or accept an arbitrary string as an ID.
struct TaskDragItem: Codable, Equatable, Sendable, Transferable {
    let taskID: UUID
    init(taskID: UUID) { self.taskID = taskID }
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .perchTask)
    }
}

struct ParkedThoughtDragItem: Codable, Equatable, Sendable, Transferable {
    let thoughtID: UUID
    init(thoughtID: UUID) { self.thoughtID = thoughtID }
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .perchParkedThought)
    }
}
