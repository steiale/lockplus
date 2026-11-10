# UI review tool

The loop for UI changes: the owner reviews screens by ID, comments are versioned in the repo, the developer sets entries to done.

    native/Tools/ui/review/review.sh              # render EN+DE, build the package, start the server, open the browser
    native/Tools/ui/review/review.sh --no-render  # reuse the PNGs in native/Tools/ui/Screenshots

- Package: `~/Code/lockplus-build/ux-review/` (`index.html`, `OVERVIEW.md`, `images/`). `index.html` is a contact sheet grouped by flow;
  each screen shows its ID large, light/dark and EN/DE side by side, numbered region markers where the manifest has them, and a comment box.
- Server: `serve.py`, stdlib only, 127.0.0.1 only, port 8765 (next free port up to 8774 if busy). Serves the package and accepts `POST /comments`.
  The page autosaves ~1 s after typing. Without the server the page still works from `file://`: comments stay in the browser
  (localStorage) and the Export buttons download Markdown or JSON.
- Comments (fixed paths, committed): `docs/native/ux-review/comments.json` and the readable mirror `docs/native/ux-review/COMMENTS.md`.
  Each entry has a status: open, done, won't do. "Open items only" in the page filters on it. To close an item, set its status
  to `done` in the page or edit `comments.json` (`"status": "done"`). Comments whose screen ID no longer exists show under "Orphaned".
  Entry keys are screen IDs (`S-1.03`) or region IDs (`S-1.03-c`).
- Server validation: JSON only (`application/json`), at most 512 KB, keys must match `S-<section>.<nn>[-<letter>]`, status must be
  open/done/wontdo, text at most 20000 characters, same-origin `Origin` only, a single route (`/comments`), no query strings.

## Manifest: `screens.json`

    { "sections": { "1": "Menu bar", ... },
      "screens": [ { "id": "S-1.03", "section": 1, "base": "menu-full-protected",
                     "title": "...", "when": "one line: when this appears", "ref": "UI-CONCEPT 6.2",
                     "regions": [ { "id": "a", "x": 0.5, "y": 0.15, "label": "Header card" } ] } ] }

- `id`: stable, never reused or renumbered (comments refer to it). New screens take the next free number in their section;
  a retired screen is removed from the manifest (its comments become orphans), its number is not given out again.
- `base`: the PNG name without `-light`/`-dark`/`-de` and `.png` in `Screenshots/` (the render tests' `name:`).
  The package copies them to `images/<id>-<base>-<light|dark>-<en|de>.png`.
- `regions`: callouts as fractions (0..1) of the image width/height, letters `a`, `b`, ...; drawn as numbered pins and listed as `S-x.yy-a`.
- `build_package.py` fails if a listed PNG is missing; the manifest should list every PNG (check: it prints the counts).

Render artefacts (offscreen capture) are listed in `OVERVIEW.md`; they are not design.
