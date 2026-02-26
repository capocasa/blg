## Common types for blg

import std/[times, strutils, unicode, envvars]

type
  SiteConfig* = object
    baseUrl*: string       # BLG_BASE_URL - prepended to relative URLs (operational)
    siteTitle*: string     # BLG_SITE_TITLE - site name for <title>
    siteDescription*: string  # BLG_SITE_DESCRIPTION - meta description

  TagInfo* = object
    slug*, label*: string  # slug for URL, label for display

  SourceFile* = object
    path*: string
    slug*: string  # Filename without extension (for URLs)
    title*: string  # Display title extracted from content <h1>
    createdAt*: Time
    createdAtHasTime*: bool  # Whether original date included time
    modifiedAt*: Time
    content*: string  # Rendered HTML content
    tags*: seq[TagInfo]  # Tags this post belongs to

  # Template interface types
  MenuItem* = object
    url*, label*: string
    active*: bool
    children*: seq[MenuItem]  # nested submenu items

  PostPreview* = object
    slug*, preview*, url*: string
    date*: Time
    dateHasTime*: bool  # Whether original date included time
    tags*: seq[TagInfo]  # Tags for linking

  PageLink* = object
    page*: int
    url*: string
    current*: bool
    ellipsis*: bool  # True if this is a "..." placeholder

proc toTagSlug*(s: string): string =
  ## Normalize string to lowercase-hyphenated form for URLs
  ## "How-To" -> "how-to", "how_TO" -> "how-to", "hOw tO" -> "how-to"
  for c in s.toLower:
    if c in {'_', ' '}:
      if result.len > 0 and result[^1] != '-':
        result.add('-')
    elif c == '-':
      if result.len > 0 and result[^1] != '-':
        result.add('-')
    else:
      result.add(c)
  # Strip trailing hyphen
  if result.len > 0 and result[^1] == '-':
    result.setLen(result.len - 1)

proc toTitleCase*(slug: string): string =
  ## Convert slug to title case for display
  ## "how-to" -> "How To"
  var capitalize = true
  for c in slug:
    if c == '-':
      result.add(' ')
      capitalize = true
    else:
      if capitalize:
        result.add(c.toUpperAscii)
        capitalize = false
      else:
        result.add(c)

proc loadSiteConfig*(): SiteConfig =
  ## Load site configuration from environment variables
  result.baseUrl = getEnv("BLG_BASE_URL", "").strip(chars = {'/'})
  result.siteTitle = getEnv("BLG_SITE_TITLE", "")
  result.siteDescription = getEnv("BLG_SITE_DESCRIPTION", "")
