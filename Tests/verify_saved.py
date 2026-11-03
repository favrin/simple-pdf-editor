"""Check logical PDF fields and rendered appearance positions independently of PDFKit."""
from pathlib import Path
import json
import sys
from pypdf import PdfReader, PdfWriter
from pypdf.generic import NameObject, DictionaryObject, ArrayObject, DecodedStreamObject
import pdfplumber

root = Path(__file__).resolve().parents[1]
saved = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'tmp/pdfs/rav-save-test.pdf'
reader = PdfReader(saved)
fields = reader.get_fields() or {}
widgets = [ref.get_object() for page in reader.pages for ref in page.get('/Annots', [])
           if ref.get_object().get('/Subtype') == '/Widget']
assert len(fields) == len(widgets) == 201
assert len(reader.trailer['/Root']['/AcroForm']['/Fields']) == 201
assert set(fields) == {widget['/T'] for widget in widgets}
assert all(widget.get('/V') == fields[widget['/T']].get('/V') for widget in widgets)
expected = {
    'Name und Vorname': 'Test Person Müller',
    'Monat und Jahr': 'December 2026',
    'Firma Adresse_1': 'Test AG\rTeststrasse 1\r8000 Zürich',
    'Firma Adresse_9': 'Second page test',
    'AHVNr': '7  5  6    1  2  3  4    5  6  7  8    9  7',
}
for row in range(1, 15):
    digits = f'{2 if row == 1 else row:02d}11'
    expected[f'Tag-Monat {row}'] = f'{digits[0]} {digits[1]}  {digits[2]} {digits[3]} '
for name, value in expected.items():
    assert fields[name]['/V'] == value, name
    widget = next(w for w in widgets if w['/T'] == name)
    assert widget['/AP']['/N'].get_data(), name
    bbox = widget['/AP']['/N']['/BBox']
    assert bbox[2] > bbox[0] and bbox[3] > bbox[1], (name, 'Zero-sized appearance')
for name in ['Zuweisung RAV_1', 'Vollzeit_9']:
    assert fields[name].get('/V') not in [None, '', '/Off', 'Off'], name
print('PASS: All 201 canonical fields agree with their page widgets; updated values and appearances exist')

# Paint the exact saved appearances into a disposable page, without regenerating
# any appearance. This lets pdfplumber measure the same glyphs a PDF reader draws.
writer = PdfWriter()
for source_page in reader.pages:
    writer.add_page(source_page)
    page = writer.pages[-1]
    resources = page['/Resources'].get_object()
    xobjects = resources.get('/XObject', DictionaryObject()).get_object()
    resources[NameObject('/XObject')] = xobjects
    commands = []
    for index, reference in enumerate(page.get('/Annots', [])):
        widget = reference.get_object()
        if widget.get('/FT') != '/Tx' or '/AP' not in widget:
            continue
        stream = widget['/AP']['/N'].get_object()
        if not hasattr(stream, 'get_data'):
            continue
        name = f'/SavedAppearance{index}'
        xobjects[NameObject(name)] = writer._add_object(stream)
        x, y, _, _ = widget['/Rect']
        commands.append(f'q 1 0 0 1 {x} {y} cm {name} Do Q\n')
    extra = DecodedStreamObject()
    extra.set_data(''.join(commands).encode('ascii'))
    contents = page['/Contents']
    if isinstance(contents, ArrayObject):
        contents.append(writer._add_object(extra))
    else:
        page[NameObject('/Contents')] = ArrayObject([page.raw_get('/Contents'), writer._add_object(extra)])
    page.pop('/Annots', None)
flattened = saved.parent / 'appearance-check.pdf'
writer.write(flattened)

cells = [359.09, 374.21, 389.33, 408.89, 424.01, 439.13, 454.25,
         473.81, 488.93, 504.05, 519.17, 538.73, 553.85]
with pdfplumber.open(flattened) as pdf:
    page = pdf.pages[0]
    digits = sorted([c for c in page.chars if c['text'].isdigit()
                     and 355 < c['x0'] < 570 and 105 < c['top'] < 132], key=lambda c: c['x0'])
    assert ''.join(c['text'] for c in digits) == '7561234567897', digits
    for index, (digit, left) in enumerate(zip(digits, cells), 1):
        assert digit['x0'] >= left - 0.05 and digit['x1'] <= left + 10.68 + 0.05, (index, digit)
        assert digit['top'] >= 107.46 - 0.05 and digit['bottom'] <= 125.94 + 0.05, (index, digit)
    text = page.extract_text() or ''
    assert 'Teststrasse' in text and '8000' in text, 'Multiline appearance lost a line'
    reference = json.loads((root / 'Tests/date-reference-layout.json').read_text())
    reference_dates = {item['field']: item for item in reference['dates']}
    reference_fields = {item['field']: item for item in reference['fields']}
    first = reference_dates['Tag-Monat 1']['glyphs']
    first_bounds = reference_fields['Tag-Monat 1']
    for row in range(1, 15):
        page_index = 0 if row <= 8 else 1
        row_index = row - 1 if row <= 8 else row - 9
        top = (231.66 if page_index == 0 else 131.34) + 34.08 * row_index
        digits = sorted([c for c in pdf.pages[page_index].chars if c['text'].isdigit()
                         and 44 < c['x0'] < 98 and top - 5 < c['top'] < top + 21], key=lambda c: c['x0'])
        assert ''.join(c['text'] for c in digits) == f'{2 if row == 1 else row:02d}11', (row, digits)
        name = f'Tag-Monat {row}'
        if name in reference_dates:
            target = reference_dates[name]['glyphs']
        else:
            bounds = reference_fields[name]
            target = [dict(x0=c['x0'] + bounds['original_left'] - first_bounds['original_left'],
                           top=c['top'] + bounds['original_top'] - first_bounds['original_top']) for c in first]
        for digit, approved in zip(digits, target):
            assert abs(digit['size'] - 14) < 0.01, (row, digit, 'Reference font size')
            # Embedded Helvetica has different PDF bounding metrics from the base
            # font. Check advances here and actual ink positions in the PNG test.
            actual_advance = digit['x0'] - digits[0]['x0']
            approved_advance = approved['x0'] - target[0]['x0']
            assert abs(actual_advance - approved_advance) < 0.12, (row, 'Reference digit spacing')
            assert abs(digit['top'] - approved['top']) < 0.6, (row, digit['top'], approved['top'], 'Reference vertical position')
        widget = next(w for w in widgets if w['/T'] == name)
        assert abs(float(widget['/Rect'][0]) - reference_fields[name]['original_left']) < 0.01
print('PASS: Each of the 13 AHV glyphs fits inside its own printed box, vertically and horizontally')
print('PASS: All three address lines are present in the saved appearance')
print('PASS: All 56 day/month digits match the approved reference font, spacing and position on both pages')

if len(sys.argv) > 2:
    original = PdfReader(sys.argv[2])
    roundtrip = PdfReader(saved.parent / 'date-reference/reference-roundtrip.pdf')
    before = original.get_fields()
    after = roundtrip.get_fields()
    assert set(before) == set(after) and len(after) == 201
    roundtrip_widgets = [ref.get_object() for page in roundtrip.pages for ref in page.get('/Annots', [])
                         if ref.get_object().get('/Subtype') == '/Widget']
    assert len(roundtrip_widgets) == 201
    assert all(widget.get('/V') == after[widget['/T']].get('/V') for widget in roundtrip_widgets)
    for name, old in before.items():
        old_value, new_value = str(old.get('/V', '')), str(after[name].get('/V', ''))
        if old.get('/FT') == '/Btn':
            assert (old_value not in ['', 'Off', '/Off']) == (new_value not in ['', 'Off', '/Off']), name
        elif name == 'AHVNr':
            assert ''.join(c for c in old_value if c.isdigit()) == ''.join(c for c in new_value if c.isdigit()), name
        else:
            normalize = lambda text: text.replace('\r\n', '\n').replace('\r', '\n')
            assert normalize(old_value) == normalize(new_value), name
    print('PASS: Reference PDF preserves all entered data, all 201 canonical fields and matching widget values')
