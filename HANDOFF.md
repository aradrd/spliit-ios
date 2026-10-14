# Handoff: attach a PDF receipt, one page at a time

> **Delete this file before opening the upstream PR** (the last step below does it). It exists
> only to carry the work from a cloud session to the MacBook, where everything runs locally.
> CI is not part of this plan.

## What this is

E-receipts and booking confirmations arrive as PDFs, and the documents grid only took photos.
The web app can show only JPEG/PNG documents (spliit#66, #397, #490), so each PDF page is drawn
to a picture on the phone and sent through the existing photo upload. That gives one
`ExpenseDocument` per page and needs no server change. Read `CLAUDE.md` — especially *Things that
will bite you* — and `DESIGN.md` before changing anything.

Branch `pdf-documents`, five commits on `main` (`2e25cb4`), plus this file:

| Commit | What |
|---|---|
| `dd6359e` | `PDFPages` in SpliitCore (CoreGraphics only) + `PDFPagesTests` |
| `e1ea067` | `DocumentUploads.attach(pdf:)`: pages drawn and uploaded one after another |
| `0040726` | *Choose Files* in the add menu, `.fileImporter` on the grid, page-limit footer |
| `92e9064` | `-uiTestPDFSample` + `ExpensePDFDocumentsTests` |
| `558a72d` | Roadmap entry |

Decisions already made, and why. Keep them unless a test or a device says otherwise:

- **First 5 pages** (`PDFPages.maximumPages`), the rest left out, not the file refused. The
  footer says *Only the first 5 pages were attached.*, held in `DocumentUploads.firstPagesOnly`
  apart from `status`, because every landed upload resets `status` to idle.
- **2048 px on the longest side, white behind, `/Rotate` honoured.** The transform is built by
  hand because `getDrawingTransform` never scales up.
- **Locked PDFs** fail with *That PDF is protected by a password.* An owner-password-only PDF
  opens.
- **Pages upload sequentially, in page order**, which keeps the gallery's order and one page in
  memory. Two PDFs picked together queue (`previousPDF`).
- **Save stays disabled while a PDF is being drawn** (`drawingPDFs` counts towards
  `isUploading`), because before the first page and between pages nothing is in flight.
- `PDFPages` holds the `Data`, not a `CGPDFDocument`, so it is `Sendable` and re-opens per page.

## Already verified

On a GitHub macOS runner at `558a72d`, with the real SDKs:

- **Unit tests** (`swift test`): 430 tests, all green. That includes every `PDFPagesTests` case:
  page count, the cap, upscaling a Letter page to 2048, landscape, the four `/Rotate` cases, the
  white background, unreadable data, a locked PDF, and an owner-only PDF.
- **App build** for the simulator, and **`check-strings.py`**: all new strings have French.

## Not yet verified (the work left)

1. `SpliitUITests` has **never been compiled**: `make build` doesn't build that target. Covers
   `ExpensePDFDocumentsTests` and the `pdfSample:` parameter added to `SpliitUITestCase.launchApp`.
2. No end-to-end run: the new test, plus the existing `ExpenseDocumentsTests` and
   `ReceiptScanTests`, whose add tile code path was touched.
3. Nothing has run on a device. *Choose Files*, the Files picker and a real PDF have never been
   tried.
4. Two small unknowns to eyeball:
   - The plural *Only the first %lld pages were attached.* has a `one` variant without `%lld`
     (EN/FR), which is never shown at 5. Check the build log for a catalogue warning.
   - The *Choose Files* menu item has its own accessibility identifier inside a `Menu` that also
     carries `documents.add`. Check with Accessibility Inspector that the item keeps its own.

## Steps on the MacBook

### 0. Toolchain (this failed last time)

The shell was using Command Line Tools: `SDKROOT` is exported pointing at
`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`, which has no `xcstringstool`. `xcodegen`
was missing.

```sh
unset SDKROOT                       # it comes from the nix/home-manager config; it returns in new shells
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # or: sudo xcode-select -s …
xcodebuild -version                 # Xcode 26 or later
make setup                          # xcodegen via brew; or: nix profile install nixpkgs#xcodegen
```

### 1. Check out

```sh
git fetch origin pdf-documents
git worktree add .claude/worktrees/pdf-documents -b pdf-documents origin/pdf-documents   # skip if it exists
cd .claude/worktrees/pdf-documents && git pull
```

### 2. Fast checks

```sh
make test       # expect 430 green, as on CI
make strings    # builds the app, then the catalogue check
```

### 3. The local server, and MinIO

`make e2e-up` needs Docker and pulls `minio/minio:latest` and `minio/mc:latest`. **MinIO has
stopped publishing community builds.** `dl.min.io` answers 410 for the archive binaries, and
Docker Hub now refuses anonymous pulls of those two images. If `docker image ls | grep minio`
already lists them, `make e2e-up` just works. If not, run MinIO natively and bring up only the
rest:

```sh
GOBIN="$HOME/.minio-bin" go install github.com/minio/minio@RELEASE.2025-09-07T16-13-09Z
GOBIN="$HOME/.minio-bin" go install github.com/minio/mc@RELEASE.2025-08-13T08-35-41Z
mkdir -p /tmp/spliit-s3/spliit
MINIO_ROOT_USER=spliit MINIO_ROOT_PASSWORD=spliitspliit \
  "$HOME/.minio-bin/minio" server /tmp/spliit-s3 --address :9009 &
until curl -sf http://localhost:9009/minio/health/live >/dev/null; do sleep 1; done
"$HOME/.minio-bin/mc" alias set e2e http://localhost:9009 spliit spliitspliit
"$HOME/.minio-bin/mc" mb --ignore-existing e2e/spliit
"$HOME/.minio-bin/mc" anonymous set download e2e/spliit
docker compose -f e2e/compose.yaml up -d --wait db app      # no s3 service
```

`make e2e` then finds the server already up and leaves Docker alone. Both tags were confirmed to
build for darwin/arm64 with Go 1.24.

### 4. End-to-end: affected suites first, then everything

```sh
make e2e SKIP_SCREENSHOTS="-only-testing:SpliitUITests/ExpensePDFDocumentsTests \
  -only-testing:SpliitUITests/ExpenseDocumentsTests -only-testing:SpliitUITests/ReceiptScanTests"
make e2e        # the full suite before upstream
```

Fix any compile errors in `SpliitUITests` first; it has never been built. `ExpensePDFDocumentsTests`
asserts the server stores exactly 2 documents, each with `max(width, height) == 2048` and a URL
that serves 200.

### 5. Device

`make device`, then in a group with document storage (spliit.app has it):

- [ ] *Choose Files* → a real multi-page PDF (an airline or hotel confirmation). The pages appear
      in order, Save is disabled until the last one lands, and the gallery shows them in order.
- [ ] A PDF with more than 5 pages → 5 attached, footer *Only the first 5 pages were attached.*
- [ ] A password-protected PDF → footer *That PDF is protected by a password.*, nothing attached.
- [ ] An image from Files → attached like a photo.
- [ ] Two PDFs picked together → the first one's pages, then the second's, not interleaved.
- [ ] A landscape or rotated page comes out the right way up. The same expense on the web app shows
      the same pictures.
- [ ] Take Photo and Choose Photos still work as before, and French reads right.
- [ ] Screenshots for the PR (light/dark, and the footer notice).

### 6. Finish

- Fix anything found, as small commits on `pdf-documents`.
- `git rm HANDOFF.md` and commit.
- Update the PR description: it is the body of the fork PR aradrd/spliit-ios#1. Change its *Ran:*
  line to what actually ran, add screenshots, and fill in the issue number.
- Close the fork PR, or leave it; it served only as CI. Open the upstream PR against
  `spliit-app/spliit-ios` from `pdf-documents`.

## Separately, for upstream (not this PR)

The MinIO change above also affects upstream CI. Its `e2e` and `upstream-drift` jobs download from
`dl.min.io` and stay green only while the `actions/cache` entry is warm, and `e2e/compose.yaml`
pulls images Docker Hub now refuses anonymously. A fix building the same pinned tags with
`go install` (shown above) is worth its own upstream PR.
