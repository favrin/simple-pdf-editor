"""Compare rendered date ink with the user's approved example at 144 dpi."""
import json
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parents[1]
reference = json.loads((root / 'Tests/date-reference-layout.json').read_text())
source = Image.open(root / 'tmp/pdfs/date-reference/reference-1.png').convert('L')
app = Image.open(root / 'tmp/pdfs/date-reference/app-reference-1.png').convert('L')
assert source.size == app.size
checked = 0
for field in reference['dates']:
    row = int(field['field'].split()[-1])
    top = 231.66 + 34.08 * (row - 1)
    centers = [(c['x0'] + c['x1']) / 2 for c in field['glyphs']]
    edges = [field['glyphs'][0]['x0'] - 3]
    edges += [(a + b) / 2 for a, b in zip(centers, centers[1:])]
    edges += [field['glyphs'][-1]['x1'] + 2]
    for index in range(4):
        box = (int(edges[index] * 2), int(top * 2) - 3,
               int(edges[index + 1] * 2), int((top + 16.02) * 2) + 3)
        ink = [im.crop(box).point(lambda x: 255 if x < 90 else 0).getbbox() for im in [source, app]]
        assert all(ink), (row, index, 'Missing digit ink')
        assert max(abs(a - b) for a, b in zip(*ink)) <= 1, (row, index, ink)
        checked += 1
print(f'PASS: All {checked} reference date digits match the rendered position and size within one pixel')
