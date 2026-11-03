# Simple PDF Editor

A small native macOS application for filling PDF forms and adding text. Built with Swift, AppKit, and PDFKit, with AI coding assistance. It works offline and has no account, server, database, or third-party runtime dependencies.

## What it does

- Open PDFs through the file picker, Finder's Open With menu, or by dragging a PDF onto the app.
- Fill existing text fields and checkboxes, with optional field highlighting.
- Add text to blank areas; edit, move, and delete added text, with Undo and Redo.
- Save the open file or use Save As to create a separate copy.
- Browse page thumbnails, zoom, and fit a page to the window.
- Handle specific field rotation, digit spacing, date layout, and multiline text issues in a two-page Swiss RAV form.

This is a personal tool that can be adapted one feature at a time. The current version does not rewrite existing printed page text, merge PDFs, insert pictures, or provide a signature tool. Those are possible future extensions, not features of this release. Adding a picture of a signature and creating a cryptographic digital signature are separate capabilities.

## Build and run

Requirements: macOS 13 or later and Apple's Xcode Command Line Tools (or Xcode). The build targets the current Mac's architecture. No packages need downloading to build the app.

1. If the Command Line Tools are not installed, run `xcode-select --install` and complete Apple's installation.
2. Clone this repository and build:

   ```sh
   git clone https://github.com/favrin/simple-pdf-editor.git
   cd simple-pdf-editor
   ./build.sh
   ```

3. Open `Simple PDF Editor.app` in Finder. You can move it to Applications or another folder.

The build creates a locally signed app. This repository distributes source; it does not provide an Apple-notarized installer. The source also retains an optional convenience behavior: if a file named `RAV copy.pdf` sits beside the app, it opens at launch. Otherwise, the welcome window lets you choose a PDF.

## Use

Click a highlighted form field to type, or click a checkbox to tick it. Tab moves between fields. For blank areas, choose Add Text and click the page. Double-click added text to edit it, drag to move it, or select it and press Delete to remove it.

Save (`Command-S`) updates the open document. Save As (`Shift-Command-S`) suggests a separate edited copy in the same folder. Closing an edited file prompts you to save. Start with copies of important documents and check the saved result in another PDF reader before relying on it.

## Checks

Run the checks that generate their own synthetic PDF:

```sh
./test.sh
```

These check PDF field and checkbox persistence, added text, Undo/Redo, and reopening the saved file. They do not require personal documents. They do not replace manual checks of the app's interactive controls or compatibility checks with your own PDFs.

The original form-specific regression suite is also included. Supply your own matching **blank** two-page RAV template to run it:

```sh
./test.sh '/path/to/blank-rav-form.pdf'
```

That suite requires macOS window services and expects 201 interactive fields with the template's original names and geometry. It writes disposable output under `tmp/pdfs/`. No form PDF or personal document is included in the repository. Optional Python checks in `Tests/` use `pypdf`, `pdfplumber`, and, for image comparisons, Pillow. The date geometry JSON contains only layout measurements.

## Licence

[MIT](LICENSE). You can use, modify, and redistribute the code, including commercially, while retaining the licence and copyright notice. The software is provided without warranty.
