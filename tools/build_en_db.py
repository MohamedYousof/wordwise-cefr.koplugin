#!/usr/bin/env python3
"""Builds the English rarity/lemma database for inlinehints.koplugin.

Three sources, each used only for the one thing it is actually good at. None of
them supply the text a reader sees: that comes from whatever StarDict dictionary
they already have, which is what keeps the plugin's output language-neutral.

  * wordfreq   -- how common a word is, so we know whether to hint it at all.
  * ECDICT     -- what a word's base form is, so "murdered" can be looked up as
                  "murder". Most dictionaries only carry lemmas, and this is the
                  single biggest cause of missed hints. ECDICT's own frequency
                  columns are NOT used; see ZIPF_TOO_COMMON for why.
  * CEFR-J     -- at what stage of learning English a reader meets a word, which
                  is a different question from how rare it is, and one no corpus
                  can answer.

wordfreq covers 42 languages, so the rarity half of another source language is
already solved. The morphology half is not: ECDICT is English-only, and the word
walk that feeds this assumes spaces between words.

Sources and licences -- the generated database inherits all of these:
  * wordfreq            Apache-2.0        pypi.org/project/wordfreq
  * ECDICT              MIT               github.com/skywind3000/ECDICT
  * CEFR-J A1-B2        free w/ citation  github.com/openlanguageprofiles/olp-en-cefrj
  * Octanove C1-C2      CC BY-SA 4.0      (same repo)

Usage:
    pip install wordfreq
    python build_en_db.py ecdict.csv inlinehints_en.sqlite3 [cefrj.csv octanove.csv]
"""

import csv
import os
import re
import sqlite3
import sys

from wordfreq import zipf_frequency

PLAIN_WORD = re.compile(r"[a-z][a-z'-]*")

# Rarity tiers, by Zipf frequency (log10 of occurrences per billion words, so
# 7 is "the", 2 is a word most readers have never met). Higher = commoner, and
# each tier is half a Zipf wide.
#
# The frequencies come from wordfreq, not from ECDICT, because ECDICT's own are
# not trustworthy: it ranked "was" 41040th and gave "are" no rank at all, which
# made two of the commonest words in English look like the rarest. That needed a
# patch -- vetoing anything CEFR called beginner vocabulary -- which only worked
# for the 7,934 words CEFR covers. Under wordfreq "was" is 6.82 and "are" 6.74,
# so the problem doesn't arise and the patch is gone. It also caught ~300 words
# ECDICT had us hinting that are nothing of the sort: aaron, alabama, amazon,
# android, anime.
#
# The cutoffs are calibrated so a reader's saved setting keeps meaning what it
# did: the ECDICT levels turned out to sit ~0.5 Zipf apart, with level 3 centred
# on 3.00 and level 5 on 1.97, so these bands are drawn around those centres.
ZIPF_TOO_COMMON = 4.25   # everyday English; never hinted, at any setting
ZIPF_CUTOFFS = [(3.75, 0), (3.25, 1), (2.75, 2), (2.25, 3), (1.75, 4)]
MAX_LEVEL = 5

# exchange field prefixes that name an inflected form of the entry word.
INFLECTION_KEYS = ("p", "d", "i", "3", "s", "r", "t")


def parse_exchange(value):
    """Turns 'p:abated/i:abating' into {'p': 'abated', 'i': 'abating'}."""
    out = {}
    for part in (value or "").split("/"):
        key, sep, val = part.partition(":")
        if sep and val:
            out[key] = val
    return out


def is_vocabulary(row):
    """Is this a word a reader could want explained, as opposed to a name?

    wordfreq is a frequency oracle, not a word list. It knows "knollenberg" and
    "beamon" because they turn up in Wikipedia and news, and being rare, they
    land in the rarest tier -- the one the most conservative setting shows.
    Sampling that tier turned up ten proper nouns, some Latin and two real words.

    So membership is ECDICT's job, not wordfreq's: a corpus rank, a Collins or
    Oxford grading, or a place on an exam list all mean a lexicographer thought
    the word worth an entry. Names have none of them.
    """
    return bool(
        int(row["frq"] or 0)
        or int(row["bnc"] or 0)
        or int(row["collins"] or 0)
        or int(row["oxford"] or 0)
        or (row["tag"] or "").strip()
    )


def level_for(zipf):
    """Maps a Zipf frequency to a rarity tier.

    Returns None for a word too common to ever hint, and for one wordfreq has
    never seen -- those are typos, fragments and proper nouns rather than words
    a reader needs help with.
    """
    if zipf <= 0 or zipf >= ZIPF_TOO_COMMON:
        return None
    for cutoff, level in ZIPF_CUTOFFS:
        if zipf >= cutoff:
            return level
    return MAX_LEVEL


def read_cefr(paths):
    """Reads CEFR-J/Octanove profiles into {headword: 'A1'..'C2'}.

    A word can appear once per part of speech ("study" as noun and as verb) at
    different levels. Keep the easiest: if a reader meets the word early in any
    role, the word itself isn't new to them.
    """
    order = {"A1": 1, "A2": 2, "B1": 3, "B2": 4, "C1": 5, "C2": 6}
    levels = {}
    for path in paths:
        with open(path, encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                word = (row.get("headword") or "").strip().lower()
                cefr = (row.get("CEFR") or "").strip().upper()
                if not PLAIN_WORD.fullmatch(word) or cefr not in order:
                    continue
                if word not in levels or order[cefr] < order[levels[word]]:
                    levels[word] = cefr
    return levels


def build(csv_path, db_path, cefr_paths=()):
    cefr = read_cefr(cefr_paths)
    lemmas = {}           # word -> (level, tags, cefr)
    form_bases = {}       # inflected form -> {possible base forms}
    csv.field_size_limit(10**7)

    with open(csv_path, encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            word = (row["word"] or "").strip().lower()
            if not PLAIN_WORD.fullmatch(word):
                continue

            exchange = parse_exchange(row["exchange"])
            tags = (row["tag"] or "").strip()

            # "0:" names this entry's base form, so the entry is an inflection
            # rather than a word in its own right.
            base = exchange.get("0", "").strip().lower()
            if base and base != word and PLAIN_WORD.fullmatch(base):
                form_bases.setdefault(word, set()).add(base)
                continue

            # The reverse direction: a lemma listing its own inflections. Some
            # of those have no entry of their own, so reading both directions
            # covers more forms than either alone.
            for key in INFLECTION_KEYS:
                inflected = exchange.get(key, "").strip().lower()
                if inflected and inflected != word and PLAIN_WORD.fullmatch(inflected):
                    form_bases.setdefault(inflected, set()).add(word)
            # A word with a CEFR level is kept whatever its frequency says. The
            # two filters answer different questions -- "how rare is this?" and
            # "how far into learning English do you meet it?" -- and a reader
            # hinting by CEFR would otherwise lose the everyday B1 words first,
            # which are exactly the ones they asked for.
            cefr_level = cefr.get(word)
            if not is_vocabulary(row) and cefr_level is None:
                continue

            level = level_for(zipf_frequency(word, "en"))
            if level is None and cefr_level is None:
                continue
            lemmas[word] = (level, tags, cefr_level)

    # An inflected form can belong to more than one word, and the two directions
    # of ECDICT's exchange field disagree about which: "does" says 0:doe, while
    # "do" says 3:does. Believing the "0:" side hinted every "does" in the book
    # as "dişi geyik". Resolve by frequency instead -- "do" is Zipf 6.4 against
    # "doe" at 3.1 -- because a reader meeting "does" has overwhelmingly met the
    # common word. It needs no special case for "does", and it leaves the
    # unambiguous forms (saw->see, found->find) alone.
    forms = {
        form: max(bases, key=lambda w: zipf_frequency(w, "en"))
        for form, bases in form_bases.items()
    }

    # A form is only useful if its lemma is glossable; drop the rest so we don't
    # ship rows that can never match.
    forms = {f: l for f, l in forms.items() if l in lemmas and f not in lemmas}

    if os.path.exists(db_path):
        os.remove(db_path)
    conn = sqlite3.connect(db_path)
    conn.executescript("""
        PRAGMA journal_mode = OFF;
        CREATE TABLE lemma (
            word  TEXT PRIMARY KEY,
            level INTEGER,   -- 1..5 rarity, NULL when only CEFR knows the word
            tags  TEXT,      -- exam lists: toefl, gre, ielts, cet4 ...
            cefr  TEXT       -- A1..C2, NULL for the vast majority
        ) WITHOUT ROWID;
        CREATE TABLE form (
            form  TEXT PRIMARY KEY,
            lemma TEXT NOT NULL
        ) WITHOUT ROWID;
    """)
    conn.executemany("INSERT INTO lemma VALUES (?, ?, ?, ?)",
                     ((w, lv, tg or None, cf) for w, (lv, tg, cf) in lemmas.items()))
    conn.executemany("INSERT INTO form VALUES (?, ?)", forms.items())
    conn.commit()
    conn.execute("VACUUM")
    conn.close()

    by_level = {}
    by_cefr = {}
    for level, _tags, cefr_level in lemmas.values():
        by_level[level] = by_level.get(level, 0) + 1
        if cefr_level:
            by_cefr[cefr_level] = by_cefr.get(cefr_level, 0) + 1
    print(f"lemmas : {len(lemmas):,}")
    for level in sorted(by_level, key=lambda x: (x is None, x)):
        print(f"  level {level if level is not None else '-'}: {by_level[level]:,}")
    if by_cefr:
        print(f"  with CEFR: {sum(by_cefr.values()):,}  " +
              " ".join(f"{k}:{by_cefr[k]:,}" for k in sorted(by_cefr)))
    print(f"forms  : {len(forms):,}")
    print(f"db     : {os.path.getsize(db_path) / 1024 / 1024:.1f} MB  {db_path}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2], sys.argv[3:])
