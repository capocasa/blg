## Date formatting with presets and custom format support
## Set BLG_DATE_FORMAT to a preset name or custom Nim times format string.

import std/[times, strutils, envvars, tables]

const DatePresets* = {  ## Named format presets for common date styles.
  "iso": "yyyy-MM-dd",             # 2000-01-01
  "us-long": "MMMM d'ord', yyyy",  # January 1st, 2000
  "us-short": "M/d/yyyy",          # 1/1/2000
  "eu-long": "d MMMM yyyy",        # 1 January 2000
  "eu-medium": "d MMM yyyy",       # 1 Jan 2000
  "eu-short": "d.M.yyyy",          # 1.1.2000
  "uk": "d'ord' MMMM yyyy",        # 1st January 2000
}.toTable

proc ordinalSuffix(day: int): string =
  ## Return "st", "nd", "rd", or "th" for a day number.
  if day in 11..13:
    return "th"
  case day mod 10
  of 1: "st"
  of 2: "nd"
  of 3: "rd"
  else: "th"

var dateFormat*: string  ## Active format string, set by initDateFormat

proc initDateFormat*() =
  ## Load BLG_DATE_FORMAT from env, default to "eu-long".
  let fmt = getEnv("BLG_DATE_FORMAT", "eu-long")
  if fmt in DatePresets:
    dateFormat = DatePresets[fmt]
  else:
    dateFormat = fmt

proc formatTime*(t: Time): string =
  ## Format Time using dateFormat, replacing 'ord' with ordinal suffix.
  let dt = t.local
  result = dt.format(dateFormat)
  # Handle ordinal day suffix: 'ord' in format becomes literal "ord" in output
  if "ord" in result:
    result = result.replace("ord", ordinalSuffix(dt.monthday))
