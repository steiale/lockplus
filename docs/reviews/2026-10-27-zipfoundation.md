# ZIPFoundation dependency review (2026-10-27)

**Scope.** Adoption review before linking ZIPFoundation into the native app (DESIGN §2.2, §3.5, §9.2, §14.2; owner approval 2026-10-27). Our use: **in-memory reading of untrusted zips** (profile import) and **in-memory writing** (Export All, diagnostics bundle). Never extraction to disk.

**Verdict: adopt 0.9.20, pinned exactly, with our own structural validator in front of every read.** On its own, ZIPFoundation is not safe for untrusted in-memory input: a 22-byte archive crashes it (F1). Every finding below is closed by code in `native/App/Services/ProfileZip.swift`, which is the only file allowed to import ZIPFoundation (lint), and by the crafted corpus and fuzz target listed at the end. Nothing here is a reason to refuse the dependency: the risky paths are structural, and we can reject them before the library sees the bytes. Inflate (Compression.framework zlib), CRC and the writer are sound for our use.

## Version and provenance

| | |
|---|---|
| Pinned | **0.9.20** (latest release, 2025-09-24; no newer tag as of 2026-10-27; `main` has only CI/README/manifest commits since) |
| Commit | `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` (annotated tag object `86fc8417…`) |
| Pin | Xcode project `exactVersion = 0.9.20`, app target only; `Package.resolved` committed; `Tools/bootstrap/pins.sh` `ZIPFOUNDATION_*` (fuzz build, commit-checked) |
| License | MIT |
| Advisories | GHSA-c2cc-3569-6jh2 / **CVE-2023-39138** (path traversal in `FileManager.unzipItem`, ≤ 0.9.17, fixed in 0.9.18; CVSS 7.8). No other advisory in the GitHub advisory database. Issues #281/#282 (path and symlink traversal) closed by 0.9.18. |
| 0.9.19 | privacy-manifest and manifest fixes only |
| 0.9.20 | resource leak in `makeBackingConfiguration`, memory leak in `Data.readChunk`, alignment crash in debug (`loadUnaligned`), `MemoryFile` and `ftello` error handling |
| Build | `swift-tools-version:5.0`, Swift 5 language mode, no C code on Darwin (Compression.framework); ships `PrivacyInfo.xcprivacy` as `ZIPFoundation_ZIPFoundation.bundle` in the app's Resources |
| Reviewed | the SPM checkout (`SourcePackages/checkouts/ZIPFoundation`, identical to the tag) — `Archive.swift`, `Archive+BackingConfiguration`, `Archive+MemoryFile`, `Archive+Reading`, `Archive+Helpers`, `Archive+ZIP64`, `Archive+Writing`, `Entry`, `Entry+Serialization`, `Entry+ZIP64`, `Data+Serialization`, `Data+Compression` |

## Findings

Each finding was checked against the code; F1, F3 and F4 were reproduced with a probe built from the tag (`~/Code/lockplus-build/zipfoundation-review/probe`, not committed).

### F1 (High for untrusted input): out-of-range offsets trap in `MemoryFile` — reproduced
- **Where:** `Archive+MemoryFile.swift` `readData`: `size = min(buffer.count, data.count - offset)` becomes negative when a seek went past the end, and `data.copyBytes(…, from: start+offset ..< start+offset+size)` traps (`Range requires lowerBound <= upperBound`). `seek` accepts any offset. The offsets come straight from the archive: the central-directory offset (EOCD), each local-header offset, the data-descriptor position.
- **Repro:** a 22-byte archive (an EOCD claiming one entry with the central directory at offset 1000) → SIGTRAP on the first iteration. A file-backed `Archive(url:)` would only short-read; the in-memory backend crashes the app.
- **Mitigation:** pass 1 (`ZipStructure.validate`) proves that every offset ZIPFoundation will seek to, and every byte range it will read, lies inside the archive before `Archive(data:)` is created. Fixture tests `centralDirectoryOutsideTheArchive`, seeds `cd-past-end.zip`, `cd-offset-huge.zip`.

### F2 (High for untrusted input): UInt64 → `off_t`/`Int64` conversions trap
- **Where:** `Data.readStruct` (`guard offset <= .max` compares against `UInt64.max`, always true, then `off_t(offset)`), `Archive.extract` (`entry.dataOffset <= .max`, same), `readUncompressed`/`readCompressed` (`Int64(size)`), and unchecked `+` in `makeIterator` (descriptor position) and `Entry.dataOffset`. All are reachable with ZIP64 values ≥ 2^63.
- **Mitigation:** ZIP64 is refused (F5), so every value ZIPFoundation uses is a 32-bit field already bounds-checked by pass 1.

### F3 (Medium): end-record scan covers the whole file — reproduced
- **Where:** `scanForEndOfCentralDirectoryRecord` walks backwards byte by byte from `len − 22` to 0 (the spec limits the comment to 65535 bytes). Each step is `fseeko` + `fread` through the `funopen` buffer. A 20 MiB file without an end record took 3.15 s of CPU; 100 MiB ≈ 16 s.
- **Mitigation:** pass 1 looks only in the spec window and refuses anything else as "not a zip", requires the end record's comment to reach exactly the end of the file, and picks the same record ZIPFoundation picks (the highest offset with the signature). Reading also runs off the main actor (`Blocking.run`).

### F4 (Medium): an encrypted entry silently ends the iteration — reproduced
- **Where:** `Entry.init?` returns nil for encrypted entries, and `makeIterator` returns nil for any record it can't parse, so `for e in archive` stops early without an error. A two-entry archive whose first entry has flag bit 0 iterates **zero** entries.
- **Mitigation:** encryption flags (bits 0, 6, 13) refuse the archive in pass 1, and pass 2 requires ZIPFoundation's iteration to yield exactly as many entries as pass 1 validated, with the same names, sizes and order.

### F5 (Medium): ZIP64 semantics are loose
- **Where:** `isZIP64` is true for version-needed ≥ 4.5 **or** any `0x0001` extra field; a ZIP64 end record is used whenever one parses, even if the classic record doesn't ask for it; an `effective*` value of 0 silently falls back to the 32-bit field; ZIP64 entries switch to 24-byte data descriptors.
- **Mitigation:** our caps (500 entries, 100 MiB) are far below every ZIP64 threshold, so pass 1 refuses ZIP64 outright: `0xFFFF`/`0xFFFFFFFF` sentinels, a ZIP64 locator before the end record, version-needed ≥ 45 (low byte, ZIPFoundation's rule), and any `0x0001` extra field in a central or local header. The user sees "uses the ZIP64 format, which isn't supported. Unpack it and import the files." (Python `force_zip64` seed `zip64.zip`.)

### F6 (Medium): CRC is computed but never compared
- **Where:** `extract(_:consumer:)` returns the CRC of what it produced; nothing compares it with `entry.checksum`. `extract(_:to:)` doesn't either.
- **Mitigation:** pass 2 requires the computed CRC to equal the central directory's CRC and `entry.checksum` (the data descriptor's, when present); pass 1 requires descriptor and local-header CRC/sizes to agree with the central directory. A mismatch skips the entry as damaged (`corrupt`). Test `malformedCentralDirectory` (CRC case).

### F7 (Medium): no bound on inflated output; local and central headers can disagree
- **Where:** `readCompressed` feeds the consumer until the deflate stream ends; the declared uncompressed size isn't enforced. `readUncompressed` loops to the central size even when the archive is shorter (empty reads, a near-endless loop for a huge claimed size). Extraction uses the **local** header's method with the **central** directory's sizes; names come from the central directory.
- **Mitigation (zip bombs):**
  - **Entry count:** ≤ 1000 central records of any kind (structural) and ≤ 500 profile entries (§3.5); over either, the archive is refused with a message, never truncated.
  - **Per-entry size:** a profile entry declaring more than 10 MiB is skipped with an error row.
  - **Total size:** declared sizes of profile entries summed (each clamped at 10 MiB + 1) must stay ≤ 100 MiB, and the inflated total is checked again while reading.
  - **Ratio:** an entry above 64 KiB that would inflate more than 100× its compressed size is skipped ("compressed suspiciously well").
  - **Output bound:** the consumer throws as soon as output passes the declared size; the result must equal it exactly. Partially filled buffers are zeroed.
  - **Overlap:** local regions (header, data, descriptor) must not overlap, which defeats the overlapping-entry (non-recursive) bomb.
  - **Consistency:** stored entries must have compressed size = uncompressed size; local and central headers must agree on name, method, flags and (without a descriptor) CRC and sizes; only methods 0 and 8.
  - Tests: `highRatioIsRefused`, `aLyingSizeStopsInflationAtTheDeclaredSize`, `overlappingEntriesAreRefused`, `entryAndTotalCaps`, `tooManyEntries`.

### F8 (Low for us): path traversal and symlinks
- **Where:** CVE-2023-39138 and #282 live in `FileManager.unzipItem` / `extract(_:to:)` (fixed in 0.9.18 with `isContained` checks; symlinks still allowed when contained). Our use never touches the file system.
- **Mitigation:**
  - lint forbids `unzipItem`, `zipItem` and `extract(…, to:)` anywhere, and forbids `import ZIPFoundation` outside `ProfileZip.swift`;
  - names are display-only (`ProfileNameSanitizer`; only the last path component is used);
  - pass 1 still flags absolute paths, drive letters, backslashes, `.`/`..`/empty components and control characters as unsafe, and those entries are skipped with an error row;
  - symlink entries (Unix mode `S_IFLNK`) and FIFOs/devices/sockets are never read; if they are named like a profile they get an error row;
  - directories are structure, not content: they are ignored, and the profiles inside them are imported by their file name. `__MACOSX/` and `._*` AppleDouble entries are ignored.

### F9 (Low): duplicate names
- **Where:** `archive[path]` returns the first match; tools differ on which duplicate they show.
- **Mitigation:** pass 1 refuses the whole archive when two entries have the same raw name or the same NFC name ("contains “x” twice").

### F10 (Info): name decoding
- **Where:** `Entry.path` decodes CP437 unless flag bit 11 is set; invalid UTF-8 with bit 11 decodes to "".
- **Mitigation:** bit 11 with invalid UTF-8 is malformed. For display we prefer UTF-8 whenever the bytes are valid UTF-8 (macOS tools often omit the flag) and fall back to CP437. To match the iteration we compare against ZIPFoundation's own decoding.

### F11 (Info): writer
- **Where:** `Archive(accessMode: .create)` into memory with `addEntry(with:type:uncompressedSize:modificationDate:permissions:compressionMethod:provider:)`. It writes version 2.1 Unix, flag bit 11, no descriptors, CRC computed while writing, and it rewrites the central directory per entry (quadratic, but negligible for ≤ 500 small files).
- **Use:** Export All and the diagnostics bundle (this replaces `/usr/bin/ditto` and its scratch directory). Entries are regular files with mode 0600 and deflate. Every archive we write is re-validated by pass 1 before it is saved (we never write what our import would refuse). The file goes through `AtomicFile.writeUserFile` (0600, `O_CREAT|O_EXCL|O_NOFOLLOW` temp, rename).

### F12 (Info): concurrency
- **Where:** `Archive` is a non-`Sendable` class wrapping a `FILE*`.
- **Use:** every `Archive` is created, used and released inside one synchronous function on one `Blocking` queue thread; none is shared or stored.

## Placement and enforcement

- **App target only:** `verify.sh static` fails if the extension binary contains any `ZIPFoundation` symbol or string, or if its bundle holds ZIPFoundation resources, and it requires the app binary to contain them. `check-symbols.sh` repeats the extension check on every built extension binary in DerivedData. The `otool -L` check stays: ZIPFoundation links statically, so `otool -L` alone would not see it.
- **Watch list:** DESIGN §9.2 dependency watch and the §22 14-day SLA cover ZIPFoundation (releases and GHSA for `github.com/weichsel/ZIPFoundation`). An upgrade means re-running this review on the diff, the crafted corpus and the fuzz smoke.

## Tests

- **Crafted corpus** (`Tests/LockPlusTests/ZipImportTests.swift`, hosted Unit plan): traversal (9 name forms), symlink, FIFO, ratio bomb, lying-size bomb, overlapping entries, too many entries (profiles and records), entry and total caps, duplicate names (exact and NFC), malformed central directory (count, size, local/central name mismatch, CRC, trailing bytes, truncation, no end record), out-of-range offsets (F1), ZIP64 (version, extra field, locator, sentinel count), encryption (F4), unsupported method, multi-disk, malformed extra field, data descriptors, nested folders with `__MACOSX`, a ditto (Finder Compress) archive, Python-written seeds, and the Export round trip (0600 entries, deflate).
- **Fuzz:** `Tools/fuzz/targets/fuzz_zip_import.swift` (ASan + SanitizerCoverage with the standalone mutation driver; libFuzzer when the toolchain allows). It runs pass 1, the full reader, and for every archive pass 1 accepts, ZIPFoundation's full iteration and capped inflation of every regular entry, asserting that the iteration count matches. Seeds: `Tools/fuzz/corpus/zip/`. Smoke run: 20 000 mutations in `build.sh run`. Before adoption, 4 × 300 000 additional mutations (seeds 2–5) ran with no report.
