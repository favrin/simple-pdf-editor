import AppKit
import PDFKit

setbuf(stdout, nil)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
func pump(_ seconds: TimeInterval) {
    let end = Date(timeIntervalSinceNow: seconds)
    while Date() < end {
        if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
    }
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let document = PDFEditorDocument()
try document.read(from: source, ofType: pdfType)
document.fileURL = source
document.fileType = pdfType
require(document.pdf.pageCount == 2, "Open both RAV pages")
require(document.pdf.page(at: 0)!.rotation == 0 && document.pdf.page(at: 1)!.rotation == 0,
        "Normalize rotated RAV pages without rasterizing the form")
let fields = (0..<document.pdf.pageCount).flatMap { document.pdf.page(at: $0)!.annotations }.filter { $0.type == "Widget" }
require(fields.count == 201, "Load all 201 interactive form fields")
require(!document.isDocumentEdited, "Opening a PDF does not mark it as edited")
func field(_ name: String) -> PDFAnnotation {
    guard let result = fields.first(where: { $0.fieldName == name }) else { fatalError("Missing field: \(name)") }
    return result
}
field("Name und Vorname").widgetStringValue = "Test Person Müller"
field("AHVNr").widgetStringValue = "7561234567897"
field("Monat und Jahr").widgetStringValue = "November 2026"
field("Firma Adresse_1").widgetStringValue = "Test AG\nTeststrasse 1\n8000 Zürich"
field("Firma Adresse_9").widgetStringValue = "Second page test"
field("Zuweisung RAV_1").buttonWidgetState = .onState
field("Vollzeit_9").buttonWidgetState = .onState
for row in 1...14 { field("Tag-Monat \(row)").widgetStringValue = String(format: "%02d11", row) }
field("Tag-Monat 9").widgetStringValue = "09/11"
document.formatDateFields()
document.detectFieldChanges()
document.formatAHVField()
require(field("AHVNr").widgetStringValue == "7  5  6    1  2  3  4    5  6  7  8    9  7", "AHV digits follow the printed 3-4-4-2 cell groups")
require(document.isDocumentEdited, "Detect changed text and checkboxes")
require(NSClassFromString("PDFEditorDocument") != nil, "Finder can resolve the registered document class")
let savePanel = NSSavePanel()
require(document.prepareSavePanel(savePanel) && savePanel.directoryURL == source.deletingLastPathComponent(),
        "Save As starts in the PDF's own folder")
document.makeWindowControllers()
let controller = document.editor!
let window = controller.window!
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
pump(0.6)
controller.pdfView.layoutDocumentView()
require(controller.pdfView.document === document.pdf, "Show the actual PDF in the native editor")
require(window.toolbar?.items.count == 10, "Build the Open / Save / Save As toolbar")
require(controller.pdfView.currentPage != nil, "Native PDF view lays out rotated pages")

// Exercise native PDFKit field editing through the app's actual view hierarchy.
let nameField = field("Monat und Jahr")
controller.pdfView.go(to: nameField.bounds, on: nameField.page!)
pump(0.2)
let fieldRect = controller.pdfView.convert(nameField.bounds, from: nameField.page!)
let point = controller.pdfView.convert(NSPoint(x: fieldRect.midX, y: fieldRect.midY), to: nil)
print("PDF frame: \(controller.pdfView.frame), bounds: \(controller.pdfView.bounds); field: \(fieldRect); click: \(point); flipped: \(controller.pdfView.isFlipped)")
print("Hit view: \(String(describing: window.contentView?.hitTest(point)))")
print("Active: \(app.isActive), key: \(window.isKeyWindow), widget editable: \(nameField.isActivatableTextField), type: \(nameField.widgetFieldType.rawValue)")
if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("before-edit.png"))
}
func click(_ at: NSPoint) {
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
    // PDFKit tracks the mouse synchronously; queue the release before dispatching down.
    app.postEvent(up, atStart: false)
    window.sendEvent(down)
}
click(point)
pump(0.2)
print("Native editing responder: \(String(describing: window.firstResponder))")
if let input = window.firstResponder as? NSTextView {
    input.selectAll(nil)
    input.insertText("December 2026", replacementRange: input.selectedRange())
    document.commitEditing()
    require(nameField.widgetStringValue == "December 2026", "Click, type and commit a native form field")
} else {
    fputs("FAIL: Clicking a text widget did not start editing\n", stderr)
    exit(1)
}

let ahv = field("AHVNr")
let ahvRect = controller.pdfView.convert(ahv.bounds, from: ahv.page!)
click(controller.pdfView.convert(NSPoint(x: ahvRect.midX, y: ahvRect.midY), to: nil))
pump(0.1)
require(window.firstResponder is NSTextView, "Click the AHV field to edit")
let ahvInput = window.firstResponder as! NSTextView
ahvInput.selectAll(nil)
ahvInput.insertText("756.1234.5678.97", replacementRange: ahvInput.selectedRange())
document.commitEditing()
require(ahv.widgetStringValue == "7  5  6    1  2  3  4    5  6  7  8    9  7", "Pasted AHV number is spaced into its 13 boxes")
require(field("Firma Adresse_1").widgetStringValue == "Test AG\rTeststrasse 1\r8000 Zürich", "Preserve multiline text using PDF line endings")
for (name, input, expected) in [("Tag-Monat 1", "2.11", "0 2  1 1 ")] {
    let date = field(name)
    controller.pdfView.go(to: date.bounds, on: date.page!)
    pump(0.1)
    let rect = controller.pdfView.convert(date.bounds, from: date.page!)
    click(controller.pdfView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
    pump(0.1)
    require(window.firstResponder is NSTextView, "Click date field: \(name)")
    let inputView = window.firstResponder as! NSTextView
    inputView.selectAll(nil)
    inputView.insertText(input, replacementRange: inputView.selectedRange())
    window.makeFirstResponder(controller.pdfView)
    pump(0.1)
    require(date.widgetStringValue == expected, "Space typed date \(input) into DD MM boxes: \(name)")
}
controller.chooseText(nil)
let blankPoint = controller.pdfView.convert(NSPoint(x: 500, y: 50), from: document.pdf.page(at: 0)!)
click(controller.pdfView.convert(blankPoint, to: nil))
pump(0.1)
require(window.attachedSheet != nil, "Add Text opens its editor when clicking the PDF page")
window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
pump(0.1)
controller.chooseFill(nil)

let page = document.pdf.page(at: 0)!
let note = PDFAnnotation(bounds: NSRect(x: 470, y: 26, width: 220, height: 44), forType: .freeText, withProperties: nil)
note.contents = "Added text test"
note.font = .systemFont(ofSize: 12)
note.fontColor = .black
note.color = .clear
note.border = PDFBorder()
note.border?.lineWidth = 0
note.shouldPrint = true
note.setValue(page.rotation, forAnnotationKey: PDFAnnotationKey(rawValue: "Rotate"))
document.add(note, to: page)
document.changeText(note, to: "Added text saved", size: 12)
require(note.contents == "Added text saved", "Added text remains editable")
pump(0.1)
document.undoManager?.undo()
require(note.page == nil, "Undo text additions")
document.undoManager?.redo()
require(note.contents == "Added text saved" && note.page === page, "Redo text additions")
let savedURL = output.appendingPathComponent("rav-save-test.pdf")
var saved = false
var saveError: Error?
document.save(to: savedURL, ofType: pdfType, for: .saveAsOperation) { error in
    saveError = error
    saved = true
}
let deadline = Date(timeIntervalSinceNow: 15)
while !saved && Date() < deadline { pump(0.05) }
require(saved && saveError == nil, "Native Save As succeeds")
require(document.fileURL == savedURL, "Save As switches to the saved copy")
require(!document.isDocumentEdited, "Successful save clears the edited indicator")
let reopened = PDFDocument(url: savedURL)!
let reopenedEditor = PDFEditorDocument()
try reopenedEditor.read(from: savedURL, ofType: pdfType)
require(!reopenedEditor.isDocumentEdited, "Reopening correctly formatted dates does not create unsaved changes")
let reopenedFields = (0..<reopened.pageCount).flatMap { reopened.page(at: $0)!.annotations }.filter { $0.type == "Widget" }
require(reopenedFields.count == 201, "Saved PDF retains every editable form field")
for row in 1...14 {
    let digits = String(format: "%02d11", row == 1 ? 2 : row)
    require(reopenedFields.first { $0.fieldName == "Tag-Monat \(row)" }?.widgetStringValue?.filter { $0.isNumber } == digits,
            "Reopen saved date: row \(row)")
}
for (name, value) in [("Name und Vorname", "Test Person Müller"), ("Monat und Jahr", "December 2026"),
                       ("Firma Adresse_1", "Test AG\rTeststrasse 1\r8000 Zürich"), ("Firma Adresse_9", "Second page test"),
                       ("AHVNr", "7  5  6    1  2  3  4    5  6  7  8    9  7")] {
    require(reopenedFields.first { $0.fieldName == name }?.widgetStringValue == value, "Reopen saved value: \(name)")
}
for name in ["Zuweisung RAV_1", "Vollzeit_9"] {
    require(reopenedFields.first { $0.fieldName == name }?.buttonWidgetState == .onState, "Reopen checked box: \(name)")
}
for index in 0..<reopened.pageCount {
    let image = reopened.page(at: index)!.thumbnail(of: NSSize(width: 1684, height: 1190), for: .cropBox)
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("saved-page-\(index + 1).png"))
}
controller.pdfView.goToFirstPage(nil)
controller.pdfView.layoutSubtreeIfNeeded()
pump(0.2)
if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("editor-window.png"))
}
document.close()
if CommandLine.arguments.count > 3 {
    let referenceURL = URL(fileURLWithPath: CommandLine.arguments[3])
    let reference = PDFDocument(url: referenceURL)!
    let referenceEditor = PDFEditorDocument()
    try referenceEditor.read(from: referenceURL, ofType: pdfType)
    let referenceOutput = output.appendingPathComponent("date-reference/reference-roundtrip.pdf")
    try referenceEditor.data(ofType: pdfType).write(to: referenceOutput, options: .atomic)
    let roundtrip = PDFDocument(url: referenceOutput)!
    func widgets(_ document: PDFDocument) -> [PDFAnnotation] {
        (0..<document.pageCount).flatMap { document.page(at: $0)!.annotations }.filter { $0.type == "Widget" }
    }
    let before = widgets(reference)
    let after = widgets(roundtrip)
    require(before.count == after.count, "Reference form retains every widget after saving")
    for original in before {
        guard let saved = after.first(where: { $0.fieldName == original.fieldName }) else { fatalError("Missing saved field") }
        if original.widgetFieldType == .button {
            require(saved.buttonWidgetState == original.buttonWidgetState, "Preserve a reference checkbox")
        } else if original.fieldName == "AHVNr" {
            require(saved.widgetStringValue?.filter { $0.isNumber } == original.widgetStringValue?.filter { $0.isNumber }, "Preserve the reference AHV digits")
        } else {
            func normalized(_ value: String?) -> String {
                (value ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            }
            require(normalized(saved.widgetStringValue) == normalized(original.widgetStringValue), "Preserve reference field contents")
        }
    }
    print("PASS: User-approved reference form roundtrips without changing its entered information")
}
print("All native app checks passed. Output: \(output.path)")
