# Inline Hints

Shows a short meaning above difficult English words as you read, in whatever
language your dictionaries are in. Similar to Kindle's Word Wise.

```
                        yaslanmak, arkaya yatmak
With its high, spine-soothing back and reclining feature, it's meditation-ready.
                                    ──────────
```

The meanings come from StarDict dictionaries you already have installed, so the
hints are in your language without anything to download. Nothing is bundled but
the data needed to decide *which* words are worth explaining.

## Using it

**Tools → Inline Hints → Show hints while reading.** It is remembered per book,
and turning it on reloads the book once (it changes the line spacing to make
room, which the engine has to re-render for).

Under **Settings**:

- **Which words get a hint** — six steps, from *only the rarest words* to *as
  many as possible*. Rarity, not length: `abate` gets a hint, `feature` doesn't.
- **How long a hint may be** — one to three meanings.
- **Dictionaries to take meanings from** — tried in the order KOReader lists
  them, and the first one with something short enough to fit wins. Turn off the
  ones that aren't a useful source: an English-English dictionary will happily
  answer with an English sentence and beat the bilingual dictionaries below it.

Tapping a word still opens the full dictionary entry, as always. A hint is a
reminder, not a replacement.

**Diagnostics** is for when a hint looks wrong. It prints each stage — the raw
entry, the text pulled out of it, the meaning chosen — to the log, which is the
only way to tell a dictionary's formatting from a real bug.

## What it does and doesn't do

It hints English words. The rarity data and the base-form table are
English-only, and the word walk assumes spaces between words, so other source
languages need their own language pack.

It has no way to tell which sense of a word is meant. Dictionaries list senses;
we take the first. This mostly stops mattering because common words don't get
hints at all — `feature` is left alone, so its wrong first sense never appears —
but a rare word with several meanings can still be hinted with the wrong one.

Names are filtered by capitalisation: a word that never appears in lower case
anywhere in the book is treated as a name. Without this, a character called Trig
gets hinted from the rare adjective "trig". The cost is a rare word that only
ever appears at the start of a sentence, which goes unhinted.

## Building the language pack

`inlinehints_en.sqlite3` ships with the plugin, so there is nothing to do unless
you want to rebuild it:

```sh
pip install wordfreq
python tools/build_en_db.py ecdict.csv inlinehints_en.sqlite3 cefrj.csv octanove.csv
```

Three sources, each doing the one thing it is good at — see the comments in
`tools/build_en_db.py` for why none of them can do the others' jobs.

## Tests

```sh
luajit tests/run_tests.lua
```

They need no KOReader and take about a second. Most of them hold real data
captured from real dictionaries and real pages, because that is where nearly
every bug in this plugin came from: the code looked right and the output was
wrong.

## Licence and credits

The plugin is AGPL-3.0 (see `LICENSE`), matching KOReader itself. The generated
language pack inherits the licences of its sources, which require attribution:

| Source | Licence | Used for |
| --- | --- | --- |
| [wordfreq](https://pypi.org/project/wordfreq/) | Apache-2.0 | How common a word is |
| [ECDICT](https://github.com/skywind3000/ECDICT) | MIT | Base forms (`murdered` → `murder`) |
| [CEFR-J Vocabulary Profile](https://github.com/openlanguageprofiles/olp-en-cefrj) | Free with citation | Learning stage, A1–B2 |
| [Octanove Vocabulary Profile C1/C2](https://github.com/openlanguageprofiles/olp-en-cefrj) | CC BY-SA 4.0 | Learning stage, C1–C2 |

Word Wise is Amazon's; this plugin is not connected to it and is only described
by comparison.
