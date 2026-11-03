import AppKit
import PDFKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

_ = NSApplication.shared
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// Generate the test document locally so no private or external fixture is needed.
let buffer = NSMutableData()
var media = CGRect(x: 0, y: 0, width: 612, height: 792)
let consumer = CGDataConsumer(data: buffer)!
let context = CGContext(consumer: consumer, mediaBox: &media, nil)!
context.beginPDFPage(nil)
context.endPDFPage()
context.closePDF()
let fixture = PDFDocument(data: buffer as Data)!
let page = fixture.page(at: 0)!
let text = PDFAnnotation(bounds: NSRect(x: 50, y: 650, width: 260, height: 32), forType: .widget, withProperties: nil)
page.addAnnotation(text)
text.widgetFieldType = .text
text.fieldName = "sample-text"
text.font = NSFont(name: "Helvetica", size: 12)
text.widgetStringValue = "Original sample"
let check = PDFAnnotation(bounds: NSRect(x: 50, y: 600, width: 20, height: 20), forType: .widget, withProperties: nil)
page.addAnnotation(check)
check.widgetFieldType = .button
check.widgetControlType = .checkBoxControl
check.fieldName = "sample-checkbox"
check.buttonWidgetState = .offState
let input = output.appendingPathComponent("synthetic-input.pdf")
require(fixture.write(to: input), "Create a synthetic PDF with text and checkbox fields")

let document = PDFEditorDocument()
try document.read(from: input, ofType: pdfType)
let livePage = document.pdf.page(at: 0)!
let liveText = livePage.annotations.first { $0.fieldName == "sample-text" }!
let liveCheck = livePage.annotations.first { $0.fieldName == "sample-checkbox" }!
liveText.widgetStringValue = "Updated sample — café"
liveCheck.buttonWidgetState = .onState
document.detectFieldChanges()
require(document.isDocumentEdited, "Changing form fields marks the document as edited")

let note = PDFAnnotation(bounds: NSRect(x: 50, y: 500, width: 200, height: 40), forType: .freeText, withProperties: nil)
note.contents = "A synthetic note"
note.font = .systemFont(ofSize: 12)
note.shouldPrint = true
document.undoManager?.groupsByEvent = false
document.undoManager?.beginUndoGrouping()
document.add(note, to: livePage)
document.undoManager?.endUndoGrouping()
document.undoManager?.undo()
require(note.page == nil, "Undo removes added text")
document.undoManager?.redo()
require(note.page === livePage, "Redo restores added text")

let saved = output.appendingPathComponent("synthetic-saved.pdf")
try document.data(ofType: pdfType).write(to: saved)
let reopened = PDFEditorDocument()
try reopened.read(from: saved, ofType: pdfType)
let annotations = reopened.pdf.page(at: 0)!.annotations
require(annotations.first { $0.fieldName == "sample-text" }?.widgetStringValue == "Updated sample — café", "Save and reopen the entered Unicode text")
require(annotations.first { $0.fieldName == "sample-checkbox" }?.buttonWidgetState == .onState, "Save and reopen a checked checkbox")
require(annotations.contains { $0.contents == "A synthetic note" && $0.type == "FreeText" }, "Save and reopen added text")
require(!reopened.isDocumentEdited, "Reopening the saved PDF starts without pending changes")
print("All synthetic PDF checks passed.")
