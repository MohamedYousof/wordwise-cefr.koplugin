local _ = require("gettext")
return {
    name = "inlinehints",
    fullname = _("Inline Hints"),
    description = _([[Shows a short meaning above difficult words as you read, taken from a dictionary you already have installed. Similar to Kindle's Word Wise.

Which words get a hint depends on how rare they are. You choose how many, how long the hints are, and which dictionaries they come from.]]),
    version = "1.0.0",
}
