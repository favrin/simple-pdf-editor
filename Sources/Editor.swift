import AppKit
import PDFKit
import UniformTypeIdentifiers

let pdfType = "com.adobe.pdf"

enum RAVDateStyle {
    static let fontSize: CGFloat = 14
    // Original widget geometry from the approved filled RAV form. Retaining its
    // row-specific positions also restores PDFs saved by earlier app versions.
    private static let tops: [CGFloat] = [223.559, 258.299, 292.063, 326.335, 360.315, 393.314,
                                         427.39, 460.664, 122.572, 156.263, 190.067, 225.616, 259.128, 292.932]
    static func bounds(for field: PDFAnnotation) -> NSRect? {
        guard let name = field.fieldName, name.hasPrefix("Tag-Monat "),
              let row = Int(name.dropFirst("Tag-Monat ".count)), (1...14).contains(row),
              let page = field.page, page.rotation == 0 else { return nil }
        let left: CGFloat = row == 2 ? 46.3206 : (row <= 8 ? 44.9185 : 44.7789)
        let height: CGFloat = 31.206
        // Keep the original left edge: embedded Mac Helvetica and the reference's
        // base font expose different side bearings. These baselines were checked
        // against rendered ink, including the sixth row's lower baseline.
        let baselineAdjustment: CGFloat = row == 6 ? 0.215 : 1.307
        return NSRect(x: left, y: page.bounds(for: .mediaBox).height - tops[row - 1] - height + baselineAdjustment,
                      width: 53.1929, height: height)
    }
}

func editorError(_ message: String) -> NSError {
    NSError(domain: "SimplePDFEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// PDFKit edits this older RAV form's /Rotate=90 widgets in the wrong orientation.
// Make the page rotation physical (vector PDF content), then rotate every annotation
// into that coordinate system. Fields stay interactive and keep their original names.
func normalizeRAVForm(_ source: PDFDocument) throws -> PDFDocument {
    let hasRAVField = (0..<source.pageCount).contains { index in
        source.page(at: index)?.annotations.contains { $0.fieldName == "AHVNr" } == true
    }
    guard hasRAVField, (0..<source.pageCount).contains(where: { source.page(at: $0)!.rotation != 0 }) else { return source }
    let result = PDFDocument()
    result.documentAttributes = source.documentAttributes
    for index in 0..<source.pageCount {
        let original = source.page(at: index)!
        guard original.rotation != 0, let pageRef = original.pageRef else {
            result.insert(original, at: result.pageCount)
            continue
        }
        let box = original.bounds(for: .mediaBox)
        let sideways = abs(original.rotation) % 180 == 90
        var media = CGRect(origin: .zero, size: sideways ? CGSize(width: box.height, height: box.width) : box.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw editorError("The rotated form could not be prepared for editing.")
        }
        let transform = pageRef.getDrawingTransform(.mediaBox, rect: media, rotate: 0, preserveAspectRatio: true)
        context.beginPDFPage(nil)
        context.concatenate(transform)
        context.drawPDFPage(pageRef)
        context.endPDFPage()
        context.closePDF()
        guard let rendered = PDFDocument(data: data as Data), let page = rendered.page(at: 0) else {
            throw editorError("The rotated form could not be prepared for editing.")
        }
        result.insert(page, at: result.pageCount)
        for annotation in original.annotations {
            let copy = annotation.copy() as! PDFAnnotation
            copy.bounds = annotation.bounds.applying(transform)
            if copy.type == "Widget" {
                let appearance = (annotation.value(forAnnotationKey: .widgetAppearanceDictionary) as? PDFAppearanceCharacteristics)?.copy() as? PDFAppearanceCharacteristics ?? PDFAppearanceCharacteristics()
                appearance.rotation = ((appearance.rotation - original.rotation) % 360 + 360) % 360
                copy.setValue(appearance, forAnnotationKey: .widgetAppearanceDictionary)
                copy.removeValue(forAnnotationKey: .appearanceDictionary)
            }
            page.addAnnotation(copy)
            if copy.type == "Widget" {
                copy.fieldName = annotation.fieldName
                copy.widgetFieldType = annotation.widgetFieldType
                if copy.widgetFieldType == .text {
                    copy.isMultiline = annotation.isMultiline
                    copy.widgetStringValue = annotation.widgetStringValue ?? ""
                } else if copy.widgetFieldType == .button {
                    copy.widgetStringValue = annotation.widgetStringValue ?? "Off"
                    copy.buttonWidgetState = annotation.buttonWidgetState
                }
            }
        }
    }
    return result
}

@objc(PDFEditorDocument)
final class PDFEditorDocument: NSDocument {
    var pdf = PDFDocument()
    private var lastFieldState: [String] = []
    private var maximumFontSizes: [String: CGFloat] = [:]
    weak var editor: EditorWindowController?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        guard let loaded = PDFDocument(url: url), loaded.pageCount > 0 else {
            throw editorError("This file could not be opened as a PDF.")
        }
        if loaded.isLocked {
            let alert = NSAlert()
            alert.messageText = "This PDF needs a password"
            alert.informativeText = "Enter the document password to open it."
            let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = password
            alert.addButton(withTitle: "Open PDF")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = password
            guard alert.runModal() == .alertFirstButtonReturn,
                  loaded.unlock(withPassword: password.stringValue) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            }
        }
        pdf = try normalizeRAVForm(loaded)
        prepareAHVField()
        formatAHVField()
        let dateLayoutChanged = prepareDateFields()
        let dateValuesChanged = formatDateFields()
        for index in 0..<pdf.pageCount {
            for field in pdf.page(at: index)!.annotations where field.type == "Widget" && field.widgetFieldType == .text {
                if let name = field.fieldName { maximumFontSizes[name] = field.font?.pointSize ?? 12 }
            }
        }
        lastFieldState = fieldState()
        editor?.setDocument(pdf)
        if dateLayoutChanged || dateValuesChanged { updateChangeCount(.changeDone) }
    }

    override func makeWindowControllers() {
        let controller = EditorWindowController(pdfDocument: self)
        editor = controller
        addWindowController(controller)
    }

    func fieldState() -> [String] {
        (0..<pdf.pageCount).flatMap { index in
            (pdf.page(at: index)?.annotations ?? []).filter { $0.type == "Widget" }.map {
                "\(index)|\($0.fieldName ?? "")|\($0.widgetStringValue ?? "")|\($0.buttonWidgetState.rawValue)"
            }
        }
    }

    func detectFieldChanges() {
        let state = fieldState()
        if state != lastFieldState {
            lastFieldState = state
            updateChangeCount(.changeDone)
        }
    }

    func commitEditing() {
        editor?.window?.makeFirstResponder(editor?.pdfView)
        formatAHVField()
        formatDateFields()
        prepareMultilineFields()
        detectFieldChanges()
    }

    private func prepareMultilineFields() {
        for index in 0..<pdf.pageCount {
            for field in pdf.page(at: index)!.annotations where field.type == "Widget" && field.widgetFieldType == .text && field.isMultiline && !field.isReadOnly {
                guard let value = field.widgetStringValue, !value.isEmpty else { continue }
                let text = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                var size = Int(maximumFontSizes[field.fieldName ?? ""] ?? 12)
                let available = NSSize(width: max(10, field.bounds.width - 6), height: max(8, field.bounds.height - 5))
                while size > 6 {
                    let font = NSFont(name: "Helvetica", size: CGFloat(size))!
                    let measured = (text as NSString).boundingRect(with: NSSize(width: available.width, height: CGFloat.greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                    if measured.height <= available.height { break }
                    size -= 1
                }
                if field.font?.pointSize != CGFloat(size) { field.font = NSFont(name: "Helvetica", size: CGFloat(size)) }
                // PDFKit's PDF appearance generator expects PDF-standard CR line ends.
                let pdfText = text.replacingOccurrences(of: "\n", with: "\r")
                if value != pdfText { field.widgetStringValue = pdfText }
            }
        }
    }

    private var ahvField: PDFAnnotation? {
        (0..<pdf.pageCount).lazy.compactMap { self.pdf.page(at: $0)?.annotations.first { $0.fieldName == "AHVNr" } }.first
    }

    private func prepareAHVField() {
        guard let field = ahvField, field.page?.rotation == 0,
              abs(field.bounds.midX - 463.18) < 12, abs(field.bounds.midY - 476.52) < 12 else { return }
        // The printed cells have larger gaps after digits 3, 7 and 11. A normal
        // equal-width comb does not match them. Match the template's original mask.
        field.bounds = NSRect(x: 357.95, y: 463.44, width: 212.574, height: 27.386)
        field.font = NSFont(name: "Helvetica", size: 13)
        field.fontColor = .black
        field.alignment = .left
        field.isMultiline = false
        field.hasComb = false
        field.maximumLength = 43
        field.removeValue(forAnnotationKey: .appearanceDictionary)
    }

    func formatAHVField() {
        guard let field = ahvField, abs(field.bounds.minX - 357.95) < 0.1 else { return }
        let value = field.widgetStringValue ?? ""
        let digits = value.filter { $0 >= "0" && $0 <= "9" }
        guard digits.count <= 13 else { return }
        let formatted = digits.enumerated().map { index, digit in
            (index == 0 ? "" : ([3, 7, 11].contains(index) ? "    " : "  ")) + String(digit)
        }.joined()
        if value != formatted { field.widgetStringValue = formatted }
    }

    private var dateFields: [PDFAnnotation] {
        guard let ahv = ahvField, abs(ahv.bounds.minX - 357.95) < 0.1 else { return [] }
        return (0..<pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }.filter {
            $0.type == "Widget" && $0.widgetFieldType == .text &&
            ($0.fieldName?.hasPrefix("Tag-Monat ") ?? false) && !$0.isReadOnly
        }
    }

    @discardableResult private func prepareDateFields() -> Bool {
        var changedFilledField = false
        for field in dateFields {
            guard abs(field.bounds.width - 53.1929) < 1, abs(field.bounds.minX - 46) < 4,
                  let bounds = RAVDateStyle.bounds(for: field) else { continue }
            if !(field.widgetStringValue ?? "").isEmpty,
               (abs(field.bounds.minX - bounds.minX) > 0.001 || abs(field.bounds.width - bounds.width) > 0.001 ||
                abs(field.bounds.minY - bounds.minY) > 0.001 || field.font?.pointSize != RAVDateStyle.fontSize) {
                changedFilledField = true
            }
            field.bounds = bounds
            field.font = NSFont(name: "Helvetica", size: RAVDateStyle.fontSize)
            field.fontColor = .black
            field.alignment = .left
            field.isMultiline = false
            field.hasComb = false
            field.maximumLength = 9
            field.removeValue(forAnnotationKey: .appearanceDictionary)
        }
        return changedFilledField
    }

    @discardableResult func formatDateFields() -> Bool {
        var changed = false
        for field in dateFields {
            guard let bounds = RAVDateStyle.bounds(for: field), abs(field.bounds.minX - bounds.minX) < 0.1 else { continue }
            let value = field.widgetStringValue ?? ""
            var digits = value.filter { $0 >= "0" && $0 <= "9" }
            let hasSeparator = value.contains(".") || value.contains("/") || value.contains("-")
            let parts = value.components(separatedBy: CharacterSet(charactersIn: "./-"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let validParts = parts.count == 2 && parts.allSatisfy { part in
                (1...2).contains(part.count) && part.allSatisfy { $0 >= "0" && $0 <= "9" }
            }
            if hasSeparator && validParts {
                digits = parts.map { part in
                    (part.count == 1 ? "0" : "") + part
                }.joined()
            }
            guard digits.count <= 4 else { continue }
            var formatted = digits.enumerated().map { index, digit in
                (index == 0 ? "" : (index == 2 ? "  " : " ")) + String(digit)
            }.joined()
            if digits.count == 4 { formatted += " " }
            if value != formatted { field.widgetStringValue = formatted; changed = true }
        }
        return changed
    }

    override func data(ofType typeName: String) throws -> Data {
        commitEditing()
        guard var data = pdf.dataRepresentation(), let exported = PDFDocument(data: data), exported.pageCount == pdf.pageCount else {
            throw editorError("The PDF could not be saved. Your document is still open; please try Save As.")
        }
        // PDFKit's live text editor can leave zero-sized appearance streams.
        // Rebuild RAV text widgets in a separate export copy, away from live views
        // and undo history, so every PDF reader gets the actual saved text.
        if let ahv = ahvField, abs(ahv.bounds.minX - 357.95) < 0.1 {
            for index in 0..<exported.pageCount {
                let page = exported.page(at: index)!
                for old in page.annotations where old.type == "Widget" && old.widgetFieldType == .text {
                    let replacement = PDFAnnotation(bounds: old.bounds, forType: .widget, withProperties: nil)
                    page.removeAnnotation(old)
                    page.addAnnotation(replacement)
                    replacement.widgetFieldType = .text
                    replacement.fieldName = old.fieldName
                    if let label = old.value(forAnnotationKey: .widgetTextLabelUI) {
                        replacement.setValue(label, forAnnotationKey: .widgetTextLabelUI)
                    }
                    if let appearance = old.value(forAnnotationKey: .widgetAppearanceDictionary) as? PDFAppearanceCharacteristics {
                        replacement.setValue(appearance.copy(), forAnnotationKey: .widgetAppearanceDictionary)
                    }
                    replacement.font = old.font ?? NSFont(name: "Helvetica", size: 12)
                    replacement.fontColor = old.fontColor ?? .black
                    replacement.alignment = old.alignment
                    replacement.isMultiline = old.isMultiline
                    replacement.hasComb = old.hasComb
                    replacement.maximumLength = old.maximumLength
                    replacement.isReadOnly = old.isReadOnly
                    replacement.border = PDFBorder()
                    replacement.border?.lineWidth = 0
                    replacement.shouldPrint = true
                    replacement.widgetStringValue = old.widgetStringValue ?? ""
                }
            }
            guard let regenerated = exported.dataRepresentation() else {
                throw editorError("The form fields could not be saved. Your document is still open.")
            }
            data = regenerated
        }
        return data
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [.pdf]
        savePanel.isExtensionHidden = false
        if let fileURL {
            savePanel.directoryURL = fileURL.deletingLastPathComponent()
            savePanel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + " - edited.pdf"
        }
        return true
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        commitEditing()
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    func add(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { $0.remove(annotation, from: page) }
        undoManager?.setActionName("Add Text")
        updateChangeCount(.changeDone)
        editor?.pdfView.needsDisplay = true
    }

    func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { $0.add(annotation, to: page) }
        undoManager?.setActionName("Remove Text")
        updateChangeCount(.changeDone)
        editor?.pdfView.selectedText = nil
        editor?.pdfView.needsDisplay = true
    }

    func changeText(_ annotation: PDFAnnotation, to text: String, size: CGFloat) {
        let oldText = annotation.contents ?? ""
        let oldSize = annotation.font?.pointSize ?? 12
        undoManager?.registerUndo(withTarget: self) { $0.changeText(annotation, to: oldText, size: oldSize) }
        undoManager?.setActionName("Edit Text")
        annotation.contents = text
        annotation.font = NSFont.systemFont(ofSize: size)
        annotation.removeValue(forAnnotationKey: .appearanceDictionary)
        updateChangeCount(.changeDone)
        editor?.pdfView.needsDisplay = true
    }

    func move(_ annotation: PDFAnnotation, to bounds: NSRect) {
        let old = annotation.bounds
        undoManager?.registerUndo(withTarget: self) { $0.move(annotation, to: old) }
        undoManager?.setActionName("Move Text")
        annotation.bounds = bounds
        updateChangeCount(.changeDone)
        editor?.pdfView.needsDisplay = true
    }
}

final class EditorPDFView: PDFView {
    weak var owner: EditorWindowController?
    var placingText = false
    var showFields = true { didSet { needsDisplay = true } }
    var selectedText: PDFAnnotation? { didSet { needsDisplay = true } }
    private var dragStart: NSPoint?
    private var dragBounds: NSRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), let page = page(for: local, nearest: false) {
            if placingText { return self }
            let pagePoint = convert(local, to: page)
            if page.annotations.contains(where: { $0.type == "FreeText" && $0.bounds.contains(pagePoint) }) { return self }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else {
            super.mouseDown(with: event)
            return
        }
        let location = convert(point, to: page)
        if placingText {
            owner?.placeText(on: page, at: location)
            return
        }
        if let annotation = page.annotations.reversed().first(where: {
            $0.type == "FreeText" && $0.bounds.contains(location)
        }) {
            window?.makeFirstResponder(self)
            selectedText = annotation
            if event.clickCount == 2 {
                owner?.editText(annotation)
            } else {
                dragStart = location
                dragBounds = annotation.bounds
            }
            return
        }
        selectedText = nil
        super.mouseDown(with: event)
        owner?.pdfDocument.detectFieldChanges()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let annotation = selectedText, let page = annotation.page,
              let start = dragStart, let original = dragBounds else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        let limits = page.bounds(for: .cropBox)
        moved.origin.x = max(limits.minX, min(moved.minX, limits.maxX - moved.width))
        moved.origin.y = max(limits.minY, min(moved.minY, limits.maxY - moved.height))
        annotation.bounds = moved
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let annotation = selectedText, let oldBounds = dragBounds {
            let newBounds = annotation.bounds
            annotation.bounds = oldBounds
            if newBounds != oldBounds { owner?.pdfDocument.move(annotation, to: newBounds) }
            dragStart = nil
            dragBounds = nil
            return
        }
        super.mouseUp(with: event)
        owner?.pdfDocument.detectFieldChanges()
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117), let annotation = selectedText, let page = annotation.page {
            owner?.pdfDocument.remove(annotation, from: page)
            return
        }
        if event.keyCode == 53 {
            selectedText = nil
            owner?.chooseFill(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        context.saveGState()
        if showFields {
            for field in page.annotations where field.type == "Widget" && !field.isReadOnly && field.shouldDisplay {
                context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.055).cgColor)
                context.fill(field.bounds)
                context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
                context.setLineWidth(0.5)
                context.stroke(field.bounds)
            }
        }
        if let annotation = selectedText, annotation.page === page {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.stroke(annotation.bounds.insetBy(dx: -2, dy: -2))
        }
        context.restoreGState()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        return true
    }
}

final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    let pdfDocument: PDFEditorDocument
    let pdfView = EditorPDFView()
    private let thumbnails = PDFThumbnailView()
    private let pageLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Click a blue field to type. Click a checkbox to tick it.")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let modeControl = NSSegmentedControl(labels: ["Fill Form", "Add Text"], trackingMode: .selectOne, target: nil, action: nil)
    private let fieldToggle = NSButton(checkboxWithTitle: "Show fields", target: nil, action: nil)

    init(pdfDocument: PDFEditorDocument) {
        self.pdfDocument = pdfDocument
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 850, height: 550)
        window.title = "Simple PDF Editor"
        window.center()
        window.setFrameAutosaveName("PDFEditorWindow")
        window.delegate = self
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "EditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        setupContent()
        setDocument(pdfDocument.pdf)
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pdfDocument.detectFieldChanges()
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, Notification.Name.PDFViewScaleChanged] {
            observers.append(center.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in self?.updateStatus() })
        }
        for name in [NSText.didChangeNotification, NSControl.textDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let view = note.object as? NSView,
                      view.window === self.window, self.window?.attachedSheet == nil else { return }
                // PDFKit commits widget values on blur. Mark pending typing immediately so
                // closing or quitting always presents the native unsaved-changes dialog.
                if !self.pdfDocument.isDocumentEdited { self.pdfDocument.updateChangeCount(.changeDone) }
            })
        }
        observers.append(center.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let view = note.object as? NSView, view.window === self.window else { return }
            DispatchQueue.main.async { [weak self] in
                self?.pdfDocument.formatAHVField()
                self?.pdfDocument.formatDateFields()
                self?.pdfDocument.detectFieldChanges()
            }
        })
    }

    required init?(coder: NSCoder) { fatalError("Use init(pdfDocument:)") }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func setupContent() {
        guard let content = window?.contentView else { return }
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 116, height: 92)
        thumbnails.backgroundColor = .windowBackgroundColor
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(thumbnails)
        NSLayoutConstraint.activate([
            thumbnails.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            thumbnails.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            thumbnails.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            thumbnails.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 138),
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 185)
        ])
        pdfView.owner = self
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 6
        pdfView.autoScales = true
        pdfView.registerForDraggedTypes([.fileURL])
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pdfView)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        let status = NSView()
        status.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        for view in [hint, pageLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            status.addSubview(view)
        }
        content.addSubview(split)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 30),
            hint.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 14),
            hint.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: pageLabel.leadingAnchor, constant: -16),
            pageLabel.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -14),
            pageLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor)
        ])
        split.setPosition(150, ofDividerAt: 0)
    }

    func setDocument(_ document: PDFDocument) {
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.selectedText = nil
        updateStatus()
        if !document.allowsFormFieldEntry {
            hint.stringValue = "This PDF does not allow form editing."
        }
    }

    func updateStatus() {
        let count = pdfDocument.pdf.pageCount
        let page = pdfView.currentPage.map { pdfDocument.pdf.index(for: $0) + 1 } ?? 1
        pageLabel.stringValue = "Page \(page) of \(count)   ·   \(Int(pdfView.scaleFactor * 100))%"
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["open", "save", "saveAs", NSToolbarItem.Identifier.flexibleSpace.rawValue, "mode", "fields",
         NSToolbarItem.Identifier.flexibleSpace.rawValue, "zoomOut", "zoomIn", "fit"].map { NSToolbarItem.Identifier($0) }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        let definitions: [String: (String, String, Selector)] = [
            "open": ("Open", "folder", #selector(openPDF)),
            "save": ("Save", "square.and.arrow.down", #selector(savePDF)),
            "saveAs": ("Save As…", "doc.badge.plus", #selector(savePDFAs)),
            "zoomOut": ("Zoom Out", "minus.magnifyingglass", #selector(zoomOut)),
            "zoomIn": ("Zoom In", "plus.magnifyingglass", #selector(zoomIn)),
            "fit": ("Fit", "arrow.up.left.and.arrow.down.right", #selector(fitPage))
        ]
        if let (label, symbol, action) = definitions[identifier.rawValue] {
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
        } else if identifier.rawValue == "mode" {
            modeControl.selectedSegment = 0
            modeControl.target = self
            modeControl.action = #selector(changeMode(_:))
            item.view = modeControl
            item.label = "Edit"
        } else if identifier.rawValue == "fields" {
            fieldToggle.state = .on
            fieldToggle.target = self
            fieldToggle.action = #selector(toggleFields)
            item.view = fieldToggle
            item.label = "Form Fields"
        }
        return item
    }

    @objc func openPDF(_ sender: Any?) { NSDocumentController.shared.openDocument(sender) }
    @objc func savePDF(_ sender: Any?) { pdfDocument.commitEditing(); pdfDocument.save(sender) }
    @objc func savePDFAs(_ sender: Any?) { pdfDocument.commitEditing(); pdfDocument.saveAs(sender) }
    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func fitPage(_ sender: Any?) { pdfView.autoScales = true }
    @objc func toggleFields(_ sender: Any?) { pdfView.showFields = fieldToggle.state == .on }
    @objc func chooseFill(_ sender: Any?) { modeControl.selectedSegment = 0; changeMode(sender) }
    @objc func chooseText(_ sender: Any?) { modeControl.selectedSegment = 1; changeMode(sender) }

    @objc func changeMode(_ sender: Any?) {
        pdfDocument.commitEditing()
        if modeControl.selectedSegment == 1 && !pdfDocument.pdf.allowsCommenting {
            modeControl.selectedSegment = 0
            NSSound.beep()
        }
        pdfView.placingText = modeControl.selectedSegment == 1
        hint.stringValue = pdfView.placingText ? "Click on the page where you want to add text. Escape cancels." :
            "Click a blue field to type. Click a checkbox to tick it."
    }

    func placeText(on page: PDFPage, at point: NSPoint) {
        textDialog(existing: nil) { [weak self] text, size in
            guard let self else { return }
            // Convert a screen-aligned rectangle through PDFView to handle rotated forms.
            let screenPoint = self.pdfView.convert(point, from: page)
            let scale = self.pdfView.scaleFactor
            let width: CGFloat = 230 * scale
            let measured = (text as NSString).boundingRect(with: NSSize(width: 224, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: size)])
            let height: CGFloat = max(40, ceil(measured.height) + 12) * scale
            let screenBounds = NSRect(x: screenPoint.x, y: self.pdfView.isFlipped ? screenPoint.y : screenPoint.y - height, width: width, height: height)
            var bounds = self.pdfView.convert(screenBounds, to: page)
            let limits = page.bounds(for: .cropBox)
            bounds.size.width = min(bounds.width, limits.width)
            bounds.size.height = min(bounds.height, limits.height)
            bounds.origin.x = max(limits.minX, min(bounds.minX, limits.maxX - bounds.width))
            bounds.origin.y = max(limits.minY, min(bounds.minY, limits.maxY - bounds.height))
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = .systemFont(ofSize: size)
            annotation.fontColor = .black
            annotation.color = .clear
            annotation.alignment = .left
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 0
            annotation.shouldPrint = true
            annotation.setValue(page.rotation, forAnnotationKey: PDFAnnotationKey(rawValue: "Rotate"))
            self.pdfDocument.add(annotation, to: page)
            self.pdfView.selectedText = annotation
            self.chooseFill(nil)
            self.hint.stringValue = "Double-click added text to edit. Drag to move. Delete removes selected text."
        }
    }

    func editText(_ annotation: PDFAnnotation) {
        textDialog(existing: annotation) { [weak self] text, size in
            self?.pdfDocument.changeText(annotation, to: text, size: size)
        }
    }

    private func textDialog(existing: PDFAnnotation?, completion: @escaping (String, CGFloat) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add text" : "Edit text"
        alert.informativeText = "Type the text to place on the PDF."
        alert.addButton(withTitle: existing == nil ? "Add Text" : "Apply")
        alert.addButton(withTitle: "Cancel")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 144))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 34, width: 380, height: 110))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.string = existing?.contents ?? ""
        textView.textContainerInset = NSSize(width: 5, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        accessory.addSubview(scroll)
        let label = NSTextField(labelWithString: "Text size")
        label.frame = NSRect(x: 0, y: 4, width: 68, height: 20)
        accessory.addSubview(label)
        let sizes = NSPopUpButton(frame: NSRect(x: 74, y: 0, width: 90, height: 26))
        sizes.addItems(withTitles: ["8", "10", "11", "12", "14", "16", "18", "24", "32"])
        sizes.selectItem(withTitle: String(Int(existing?.font?.pointSize ?? 12)))
        accessory.addSubview(sizes)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = textView
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            completion(textView.string, CGFloat(Double(sizes.titleOfSelectedItem ?? "12") ?? 12))
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { pdfDocument.undoManager }
    func windowWillClose(_ notification: Notification) { timer?.invalidate() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard NSDocumentController.shared.documents.isEmpty else { return }
            let folder = Bundle.main.bundleURL.deletingLastPathComponent()
            let adjacent = folder.appendingPathComponent("RAV copy.pdf")
            if FileManager.default.fileExists(atPath: adjacent.path) {
                NSDocumentController.shared.openDocument(withContentsOf: adjacent, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            } else { self?.showWelcome() }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    @objc func showWelcome() {
        if let welcome { welcome.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Simple PDF Editor"
        window.isReleasedWhenClosed = false
        window.center()
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemTeal
        icon.frame = NSRect(x: 238, y: 248, width: 64, height: 64)
        let title = NSTextField(labelWithString: "Simple PDF Editor")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 40, y: 196, width: 460, height: 34)
        let subtitle = NSTextField(wrappingLabelWithString: "Open a PDF, fill in its fields, and save.\nYou can also drag a PDF onto the app icon.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 40, y: 128, width: 460, height: 48)
        let button = NSButton(title: "Open PDF…", target: self, action: #selector(openFromWelcome))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 195, y: 70, width: 150, height: 34)
        let note = NSTextField(labelWithString: "Works offline · Your files stay on this Mac")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        note.frame = NSRect(x: 40, y: 28, width: 460, height: 20)
        for view in [icon, title, subtitle, button, note] { window.contentView?.addSubview(view) }
        welcome = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openFromWelcome(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
        if !NSDocumentController.shared.documents.isEmpty { welcome?.orderOut(nil) }
    }

    private func buildMenus() {
        let main = NSMenu()
        NSApp.mainMenu = main
        func menu(_ name: String) -> NSMenu {
            let parent = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: name)
            parent.submenu = submenu
            main.addItem(parent)
            return submenu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = menu("Simple PDF Editor")
        item(app, "About Simple PDF Editor", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app, "Hide Simple PDF Editor", #selector(NSApplication.hide(_:)), "h")
        app.addItem(.separator())
        item(app, "Quit Simple PDF Editor", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        file.addItem(.separator())
        item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        item(file, "Save", #selector(NSDocument.save(_:)), "s")
        item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        item(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        let edit = menu("Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let view = menu("View")
        item(view, "Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+")
        item(view, "Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-")
        item(view, "Fit to Window", #selector(EditorWindowController.fitPage(_:)), "0")
        view.addItem(.separator())
        item(view, "Fill Form", #selector(EditorWindowController.chooseFill(_:)), "1")
        item(view, "Add Text", #selector(EditorWindowController.chooseText(_:)), "2")
        let window = menu("Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window
        let help = menu("Help")
        let helpItem = NSMenuItem(title: "How to use Simple PDF Editor", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        help.addItem(helpItem)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Fill in a PDF and save it"
        alert.informativeText = "1. Open a PDF, or drag it onto the app icon.\n\n2. Click a blue form field and type. Click checkboxes to tick them. Tab moves between form fields.\n\n3. Use Save (⌘S) to update the file, or Save As (⇧⌘S) to keep a separate copy in the same folder.\n\nFor a PDF without fields, choose Add Text and click the page. Double-click added text to edit it; drag to move it; press Delete to remove it.\n\nThe app fills forms and adds text. Existing printed page text is not rewritten."
        alert.addButton(withTitle: "Got It")
        alert.runModal()
    }
}
