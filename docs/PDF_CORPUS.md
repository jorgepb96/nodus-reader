# PDF reflow corpus checks

The parser is exercised against a shared 50-document corpus kept outside the
repository. The documents themselves, OCR output and reflow caches are never
committed.

## Composition

- 27 arXiv papers from 15 categories (cs.CL, cs.CV, cs.LG, stat.ML, math.NT,
  math.AP, hep-th, cond-mat.stat-mech, econ.GN, q-fin.GN, eess.AS, cs.HC,
  cs.SE, physics.soc-ph, q-bio.NC).
- 22 open-access humanities/social-science PDFs found through OpenAlex:
  tourism history, photography, travel writing, heritage and Alfonso X.
- The one accessible full text by Jorge Pérez Burgueño:
  *Análisis cuantitativo de los diarios de pioneros…* (Vínculos de Historia,
  2023, DOI 10.18239/vdh_2023.12.21). His Dialnet profile lists six works;
  the two Ruidera book/chapter PDFs returned HTTP 403 from the publisher's
  Azure WAF during this run, so only their metadata was checked.

## Running the probe

```bash
tools/parser-probe/build.sh
tools/parser-probe/.build/probe pdf paper.pdf --pages 400 --reflow \
  --markdown /tmp/paper.md
```

The probe uses the same `PDFReflowExtractor` and `markdown()` code as the app.
To rerun the corpus, pass each file with `--pages 400 --reflow --markdown`.

## What the corpus exposed and what changed

- A two-column PDF was interleaved because table reconstruction sorted blocks
  by `rect.minY` after reading order was already decided. The sort is gone.
- Centred author/affiliation lines made column-gutter detection fail; columns
  are now detected with median edges and short centred lines are ordered first.
- Same-baseline left/right fragments were merged across the gutter; the merge
  gap is now bounded and never crosses the two column sides.
- Bold IEEE abstracts and emphasized body lines were promoted to headings; a
  size heading must be short, and bold body runs are suppressed.
- Footnote continuations were emitted as bullet lists. A page-level footnote
  run now starts on a small numbered note and captures its continuation.
- Bibliography entries were merged into one paragraph. Author-initial patterns
  start a new reference block.
- Embedded fonts split “fi”/“fl” ligatures as `fi n`, `confl ictos`; these are
  rejoined, and a leftover table row after a table image is dropped.
- The SwiftUI import banner now uses `palette.text`, so it follows the selected
  theme instead of relying on the system default foreground.
- A successful import sets `ImportCoordinator.bookToOpen`; the root presents
  the imported book in the reader once, while multiple imports open the first
  one.
