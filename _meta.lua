local _ = require("gettext")
return {
    name = "inlinehints",
    fullname = _("Inline Hints (CEFR)"),
    description = _([[Shows a short meaning above difficult words as you read, taken from a dictionary you already have installed. Similar to Kindle's Word Wise.

Which words get a hint depends on YOUR English level: pick CEFR A1-C2 and a word is explained when its learner level is above yours (real CEFR-J/Octanove data, not a frequency guess). You choose the hint font and size, how long the hints are, and which dictionaries they come from -- with two bundled fallback dictionaries (English-Arabic and English definitions) if your installed ones aren't enough.

A fork of omer-faruq's Inline Hints; Arabic and other right-to-left hints are properly shaped and ordered.]]),
    version = "1.1.0",
}
