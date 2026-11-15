"""Keep the capture and drag producers connected to their regression-tested rules."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ChecklistCaptureIntegrationTests(unittest.TestCase):
    def test_speech_does_not_assign_or_clear_the_typed_field(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        callback = source.split("private func addDictation(", 1)[1].split("private func submit(", 1)[0]
        self.assertIn("capture.submitDictation(spoken, parentID: parentID)", callback)
        self.assertNotIn("capture.text =", callback)
        self.assertNotIn("add()", callback)
        self.assertIn("addDictation(pending, parentID: capture.pendingDictationParentID)", source)
        self.assertIn("text: $capture.text", source)

    def test_preview_and_voice_presentation_use_live_sources(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        self.assertIn("capture.preview(using: store.capture, language: language)", source)
        self.assertNotIn("store.capture.parse(text", source)
        self.assertIn("@ObservedObject var voice: VoiceCapture", source)
        self.assertIn("isDictating: voice.state == .listening", source)
        self.assertIn("case .error(let message):", source)
        self.assertIn("Text(message)", source)
        for marker in ("capture-listening", "capture-dictation-error"):
            self.assertIn(marker, source)
        for target in ("checklist-dictating", "checklist-voice-error", "checklist-multiline"):
            self.assertIn("--open " + target, (ROOT / "scripts/redesign_shots.list").read_text())

    def test_dictation_arguments_follow_shared_initializer_order(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TasksCard.swift").read_text()
        call = source.split("            AddField(", 1)[1].split("            switch voice.state", 1)[0]
        self.assertLess(call.index("isDictating:"), call.index("onSubmit:"))
        self.assertLess(call.index("onSubmit:"), call.index("onDictate:"))

    def test_drag_has_typed_identity_and_legacy_text_representation(self):
        source = (ROOT / "Sources/PerchApp/Workspace/TaskRow.swift").read_text()
        self.assertIn(".onDrag { ChecklistTaskDrag.provider(for: task.id) }", source)
        self.assertIn("NSItemProvider(object: id.uuidString as NSString)", source)
        self.assertIn("JSONEncoder().encode(TaskDragItem(taskID: id))", source)
        self.assertIn("UTType.perchTask.identifier", source)
        self.assertIn("visibility: .ownProcess", source)
        native = (ROOT / "Tests/PerchAppTests/ChecklistTaskDragTests.swift").read_text()
        self.assertIn("loadDataRepresentation", native)
        self.assertIn("loadObject(ofClass: NSString.self)", native)
        self.assertIn("XCTAssertEqual(UUID(uuidString: legacy), id)", native)


if __name__ == "__main__":
    unittest.main()
