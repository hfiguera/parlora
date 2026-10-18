"""Conservative English numeric-entity comparison, independent of strict WER.

This is a deterministic formatting comparison, not an LLM semantic judge. Entity
order and units matter; unresolved forms are surfaced for review.
"""

import re
import unicodedata
from decimal import Decimal
from datetime import date

VERSION = 1
SMALL = dict(
    zip(
        "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(),
        range(20),
    )
)
TENS = dict(
    zip(
        "twenty thirty forty fifty sixty seventy eighty ninety".split(),
        range(20, 100, 10),
    )
)
SCALES = {"thousand": 1000, "million": 1000000, "billion": 1000000000}
ORDINALS = dict(
    zip(
        "first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth".split(),
        range(1, 20),
    )
)
ORDINALS.update(
    dict(
        zip(
            "twentieth thirtieth fortieth fiftieth sixtieth seventieth eightieth ninetieth hundredth thousandth".split(),
            [20, 30, 40, 50, 60, 70, 80, 90, 100, 1000],
        )
    )
)
MONTHS = dict(
    zip(
        "january february march april may june july august september october november december".split(),
        range(1, 13),
    )
)
UNITS = {
    w: w
    for w in "day week month year hour minute second calorie dollar cent percent kilogram gram pound liter litre mile kilometer meter foot inch celsius fahrenheit euro".split()
}
UNITS.update({w + "s": w for w in list(UNITS)})
UNITS.update(
    {
        "%": "percent",
        "kg": "kilogram",
        "g": "gram",
        "lb": "pound",
        "lbs": "pound",
        "usd": "dollar",
        "dollars": "dollar",
        "feet": "foot",
        "inches": "inch",
        "litres": "liter",
        "litre": "liter",
        "c": "celsius",
        "f": "fahrenheit",
        "eur": "euro",
        "gbp": "gbp",
    }
)
IDENTIFIER = re.compile(
    r"(?:\b(?:zip|postcode|pin)\b|\b(?:phone|telephone|order|tracking|flight|office|extension|account|confirmation|card) (?:number|id|code)\b|\bnumber ending in\b)"
)
DECADES = dict(
    zip(
        "twenties thirties forties fifties sixties seventies eighties nineties".split(),
        range(20, 100, 10),
    )
)
TOKEN = re.compile(
    r"\d{2,4}s\b|\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}|\d+(?:,\d{3})*(?:\.\d+)?(?:st|nd|rd|th)?|[a-z]+|[$€£%/+−-]"
)


def cardinal(tokens, start):
    """Consume a standard cardinal phrase; never read 'seven eighty' as 783."""
    total = group = 0
    scale_limit = float("inf")
    phase = "empty"
    i = start
    while i < len(tokens):
        token = tokens[i]
        if token in SMALL and phase in ("empty", "hundred", "tens"):
            value = SMALL[token]
            if phase == "tens" and not 0 < value < 10:
                break
            group += value
            phase = "small"
        elif token in TENS and phase in ("empty", "hundred"):
            group += TENS[token]
            phase = "tens"
        elif token == "hundred" and phase == "small" and 0 < group < 10:
            group *= 100
            phase = "hundred"
        elif token in SCALES and group > 0 and SCALES[token] < scale_limit:
            scale_limit = SCALES[token]
            total += group * scale_limit
            group = 0
            phase = "empty"
        elif (
            token == "and"
            and i > start
            and (phase == "hundred" or (phase == "empty" and total))
            and i + 1 < len(tokens)
            and tokens[i + 1] in SMALL | TENS
        ):
            pass
        else:
            break
        i += 1
    if i == start:
        return None
    if tokens[i - 1] == "and":
        i -= 1
    return str(total + group), i, False


def number(tokens, start):
    token = tokens[start]
    if token in ("a", "an") and start + 1 < len(tokens):
        if tokens[start + 1] in UNITS:
            return "1", start + 1, False
        if tokens[start + 1] in SCALES or tokens[start + 1] == "hundred":
            return cardinal(tokens[:start] + ["one"] + tokens[start + 1 :], start)
    if re.fullmatch(r"\d+(?:,\d{3})*(?:\.\d+)?(?:st|nd|rd|th)?", token):
        ordinal = bool(re.search(r"(st|nd|rd|th)$", token))
        raw = re.sub(r"(st|nd|rd|th)$", "", token).replace(",", "")
        value = format(Decimal(raw), "f")
        if "." in value:
            value = value.rstrip("0").rstrip(".")
        end = start + 1
        if (
            not ordinal
            and end < len(tokens)
            and tokens[end] in SCALES | {"hundred": 100}
        ):
            value = format(
                (Decimal(value) * (SCALES | {"hundred": 100})[tokens[end]]).normalize(),
                "f",
            )
            end += 1
        return value, end, ordinal
    # Replace a terminal ordinal with its cardinal spelling, preserving grammar.
    for end in range(start, min(start + 12, len(tokens))):
        if tokens[end] in ORDINALS:
            value = ORDINALS[tokens[end]]
            word = next((k for k, v in (SMALL | TENS).items() if v == value), None)
            word = word or {100: "hundred", 1000: "thousand"}[value]
            candidate = tokens[start:end] + [word]
            parsed = cardinal(candidate, 0)
            if parsed and parsed[1] == len(candidate):
                return parsed[0], end + 1, True
            break
        if tokens[end] not in SMALL | TENS | SCALES and tokens[end] not in (
            "hundred",
            "and",
        ):
            break
    parsed = cardinal(tokens, start)
    if parsed and parsed[1] < len(tokens) and tokens[parsed[1]] == "point":
        end = parsed[1] + 1
        digits = []
        while end < len(tokens) and (
            tokens[end] in SMALL
            and SMALL[tokens[end]] < 10
            or re.fullmatch(r"\d+", tokens[end])
        ):
            digits.append(
                str(SMALL[tokens[end]]) if tokens[end] in SMALL else tokens[end]
            )
            end += 1
        if digits:
            return (
                format(Decimal(parsed[0] + "." + "".join(digits)).normalize(), "f"),
                end,
                False,
            )
    return parsed


def entities(text):
    text = unicodedata.normalize("NFKC", text).casefold()
    text = re.sub(r"\b([ap])\.?\s*m\.?\b", r"\1m", text)
    text = re.sub(r"(?<=[a-z])-(?=[a-z])", " ", text)
    tokens = TOKEN.findall(text)
    found, review = [], []
    if re.search(r"\d\s*/\s*\d", text):
        review.append("Slash dates/fractions require review; no date-order assumption.")
    if re.search(
        r"\b(?:half|quarter|double|triple)\b", re.sub(r"\bdouble check\b", "", text)
    ):
        review.append("Fractional or repeated-digit wording requires review.")
    i = 0
    while i < len(tokens):
        token = tokens[i]
        context = " ".join(tokens[max(0, i - 8) : i])
        identifier = bool(IDENTIFIER.search(context))
        start = i
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", token):
            try:
                date.fromisoformat(token)
            except ValueError:
                review.append("Invalid calendar date requires review.")
            found.append(("date", token, ""))
            i += 1
            continue
        if token in DECADES or re.fullmatch(r"\d{2,4}s", token):
            if i and tokens[i - 1] == "the":
                found.append(
                    (
                        "decade",
                        str(DECADES[token]) if token in DECADES else token[:-1],
                        "",
                    )
                )
            else:
                review.append("Decade/seconds shorthand requires review.")
            i += 1
            continue
        clock = re.fullmatch(r"(\d{1,2}):(\d{2})", token)
        parsed = number(tokens, i) if not clock else (clock[1], i + 1, False)
        if not parsed:
            i += 1
            continue
        value, end, ordinal = parsed
        unit = ""
        kind = "ordinal" if ordinal else "quantity"
        if identifier and not ordinal:
            # Digit-by-digit identifiers preserve zeros and order, including
            # punctuation-separated groups. Other cardinal phrases keep their value.
            cursor, digits = i, []
            while cursor < len(tokens):
                t = tokens[cursor]
                if t in SMALL and SMALL[t] < 10:
                    digits.append(str(SMALL[t]))
                elif re.fullmatch(r"\d+", t):
                    digits.append(t)
                elif (
                    t == "-"
                    and digits
                    and cursor + 1 < len(tokens)
                    and tokens[cursor + 1].isdigit()
                ):
                    cursor += 1
                    continue
                else:
                    break
                cursor += 1
            if digits and cursor >= end:
                value, end = "".join(digits), cursor
            kind = "identifier"
        elif clock or (
            not ordinal and end < len(tokens) and tokens[end] in ("am", "pm")
        ):
            minute = int(clock[2]) if clock else 0
            hour = int(value) if value.isdigit() else -1
            meridian = (
                tokens[end] if end < len(tokens) and tokens[end] in ("am", "pm") else ""
            )
            if 0 <= minute < 60 and (1 <= hour <= 12 if meridian else 0 <= hour <= 23):
                if meridian:
                    hour = hour % 12 + (12 if meridian == "pm" else 0)
                    end += 1
                value, kind = f"{hour:02}:{minute:02}", "time"
            else:
                review.append("Invalid clock form requires review.")
        elif (
            not ordinal
            and value.isdigit()
            and 1 <= int(value) <= 12
            and end < len(tokens)
        ):
            minutes = number(tokens, end)
            if (
                minutes
                and not minutes[2]
                and minutes[0].isdigit()
                and 0 <= int(minutes[0]) < 60
            ):
                minute, finish, _ = minutes
                meridian = (
                    tokens[finish]
                    if finish < len(tokens) and tokens[finish] in ("am", "pm")
                    else ""
                )
                if meridian or (i and tokens[i - 1] in ("at", "around", "by")):
                    hour = (
                        int(value) % 12 + (12 if meridian == "pm" else 0)
                        if meridian
                        else int(value)
                    )
                    value, kind, end = (
                        f"{hour:02}:{int(minute):02}",
                        "time",
                        finish + bool(meridian),
                    )
        if kind in ("quantity", "ordinal"):
            month = tokens[i - 1] if i else ""
            after = end + (1 if end < len(tokens) and tokens[end] == "of" else 0)
            if month not in MONTHS and after < len(tokens) and tokens[after] in MONTHS:
                month, end = tokens[after], after + 1
            if month in MONTHS and value.isdigit() and 1 <= int(value) <= 31:
                value, kind = f"{MONTHS[month]:02}-{int(value):02}", "date_day"
                if end < len(tokens) and re.fullmatch(r"\d{4}", tokens[end]):
                    value, kind, end = tokens[end] + "-" + value, "date", end + 1
            elif month in MONTHS and re.fullmatch(r"\d{4}", value):
                value, kind = f"{value}-{MONTHS[month]:02}", "date_month"
            else:
                unit_at = end + (1 if end < len(tokens) and tokens[end] == "-" else 0)
                if (
                    unit_at + 1 < len(tokens)
                    and tokens[unit_at] in ("degree", "degrees")
                    and tokens[unit_at + 1] in ("celsius", "fahrenheit", "c", "f")
                ):
                    unit_at += 1
                if unit_at < len(tokens) and tokens[unit_at] in UNITS:
                    unit, end = UNITS[tokens[unit_at]], unit_at + 1
                prefix = (
                    tokens[i - 2]
                    if i > 1 and tokens[i - 1] in ("-", "−")
                    else (tokens[i - 1] if i else "")
                )
                if prefix in ("$", "€", "£"):
                    unit = {"$": "dollar", "€": "euro", "£": "gbp"}[prefix]
                if i and tokens[i - 1] in ("minus", "negative", "−"):
                    value = "-" + value
                # An attached ASCII minus is distinguished from a hyphenated range.
                if (
                    i
                    and tokens[i - 1] == "-"
                    and (i < 2 or not tokens[i - 2].isdigit())
                ):
                    value = "-" + value
        if kind == "date":
            try:
                date.fromisoformat(value)
            except ValueError:
                review.append("Invalid calendar date requires review.")
        found.append((kind, value, unit))
        if end < len(tokens) and (tokens[end] in SMALL | TENS or tokens[end].isdigit()):
            review.append("Adjacent number expressions require review.")
        i = max(start + 1, end)
    return found, sorted(set(review))


def compare(reference, hypothesis, distance):
    ref, ref_review = entities(reference)
    hyp, hyp_review = entities(hypothesis)
    return {
        "reference_entities": ref,
        "hypothesis_entities": hyp,
        "reference_entity_count": len(ref),
        "errors": distance(ref, hyp),
        "exact_match": ref == hyp,
        "review_required": bool(ref_review or hyp_review),
        "reference_review": ref_review,
        "hypothesis_review": hyp_review,
    }
