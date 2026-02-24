## Date formatting with presets and custom format support
##
## Environment: BLG_DATE_FORMAT
## Presets: iso, us-long, us-short, eu-long, eu-medium, eu-short, uk
## Or use a custom format string (Nim times module syntax)

import std/[times, strutils, envvars, tables]

const DatePresets* = {
  "iso": "yyyy-MM-dd",             # 2000-01-01
  "us-long": "MMMM d'ord', yyyy",  # January 1st, 2000
  "us-short": "M/d/yyyy",          # 1/1/2000
  "eu-long": "d MMMM yyyy",        # 1 January 2000
  "eu-medium": "d MMM yyyy",       # 1 Jan 2000
  "eu-short": "d.M.yyyy",          # 1.1.2000
  "uk": "d'ord' MMMM yyyy",        # 1st January 2000
}.toTable

proc ordinalSuffix(day: int): string =
  ## Return ordinal suffix for a day number (1st, 2nd, 3rd, 4th, etc.)
  if day in 11..13:
    return "th"
  case day mod 10
  of 1: "st"
  of 2: "nd"
  of 3: "rd"
  else: "th"

var dateFormat*: string

proc initDateFormat*() =
  ## Initialize date format from environment (call after loading .env)
  let fmt = getEnv("BLG_DATE_FORMAT", "eu-long")
  if fmt in DatePresets:
    dateFormat = DatePresets[fmt]
  else:
    dateFormat = fmt

proc formatTime*(t: Time): string =
  ## Format a Time value according to the configured date format
  let dt = t.local
  result = dt.format(dateFormat)
  # Handle ordinal day suffix: 'ord' in format becomes literal "ord" in output
  if "ord" in result:
    result = result.replace("ord", ordinalSuffix(dt.monthday))
