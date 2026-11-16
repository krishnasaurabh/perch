#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers
    import XCTest
    @testable import PerchApp

    final class ChecklistTaskDragTests: XCTestCase {
        @MainActor
        func testRowExportsSameIdentityForTypedAndLegacyDropDestinations() async throws {
            let id = UUID()
            let provider = ChecklistTaskDrag.provider(for: id)
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.perchTask.identifier))
            XCTAssertTrue(provider.canLoadObject(ofClass: NSString.self))
            let typed = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.perchTask.identifier) { data, error in
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
            XCTAssertEqual(try JSONDecoder().decode(TaskDragItem.self, from: typed).taskID, id)
            let legacy = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                _ = provider.loadObject(ofClass: NSString.self) { value, error in
                    if let value = value as? String {
                        continuation.resume(returning: value)
                    } else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
            XCTAssertEqual(UUID(uuidString: legacy), id)
        }
    }
#endif
