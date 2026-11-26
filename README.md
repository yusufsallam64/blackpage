# Blackpage

Tiny native macOS markdown editor for focused, distraction-free writing sessions. No third-party dependencies!

## Install

Requires macOS 13 or later and a Swift 5.9+ toolchain (Xcode or the Command
Line Tools).

    ./build.sh          # builds build/Blackpage.app (ad-hoc signed)
    ./install.sh        # builds, quits a running copy, copies to /Applications

## Keys

⌘/ shows all of these in the app.

| Key | |
|---|---|
| ⌘K | Command palette |
| ⌘P | Find file (in the browser folder, plus drafts) |
| ⌘F | Search this document (fuzzy; empty query lists headings) |
| ⌥⌘F, ⌘G | Exact find and replace, next match |
| ⌘E | File browser (press again to focus/hide; j k l h inside) |
| ⇧⌘O | Pick the browser folder |
| ⌘↩ | Zen mode. Esc leaves |
| ⌘B ⌘I | Bold, italic |
| ⌘' | Add a note `<!-- like this -->` (hidden when the markdown is rendered) |
| ⌘J, ⌥⌘↑ ⌥⌘↓ | Jump to a note, previous / next note |
| Tab ⇧Tab | Indent, outdent list items |
| ⌘T | Typewriter scrolling |
| ⇧⌘D | Dim other paragraphs |
| ⌘; | Spell check |
| ⇧⌘C | Copy as rich text (selection or whole piece, notes removed) |
| ⇧⌘E | Export PDF. Export HTML is in ⌘K |
| ⌃⌘V | Vim keys |
| ⌘= ⌘- ⌘0 | Text size. View > Font for serif, sans, mono |

Pickers: ⌃J ⌃K or ⌃N ⌃P to move, Return to open, Esc to close.

## History and replay

Per file, in `~/Library/Application Support/Blackpage/History/`:

- Versions: a snapshot when you open a file, every 5 minutes you write, and on
  close.
- Replay: every edit is logged with its timing and compressed when the session
  ends (~160 KB for a 10k-word essay typed from scratch). ⌘K → Replay Writing.
  Pauses over 1.5s are squeezed out. Space pauses, 1–4 set speed (1×–64×),
  ← → skip 30s, click the bottom bar to scrub, Esc closes.

## Vim

Prose-flavoured subset. j/k move by wrapped line, a "line" for dd/yy/cc is a
paragraph, apostrophes are part of words. Orange caret = normal mode.

Motions h j k l w b e 0 ^ $ gg G { } ( ) with counts. Edits i a I A o O x X s
S D C J r p P u ⌃R, v, >> <<. Operators d c y with motions, dd cc yy dgg dG,
text objects iw aw is as ip ap. Search / n N.
