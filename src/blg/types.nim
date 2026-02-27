## Common types for blg
## Shared data structures for source files, menus, and site config.

import std/[times, strutils, unicode, envvars]

type
  SiteConfig* = object
    ## Site-wide settings loaded from environment variables.
    baseUrl*: string          ## Prepended to relative URLs for absolute links
    siteTitle*: string        ## Site name shown in header and <title>
    siteDescription*: string  ## Meta description for SEO

  TagInfo* = object
    ## Tag identifier with URL-safe slug and display label.
    slug*: string   ## Lowercase hyphenated form for URLs
    label*: string  ## Title case for display

  SourceFile* = object
    ## Parsed markdown file with extracted metadata.
    path*: string             ## Absolute filesystem path
    slug*: string             ## Filename without extension, used for URLs
    title*: string            ## First H1 heading from content
    createdAt*: Time          ## Post date from first line or file mtime
    createdAtHasTime*: bool   ## True if source included HH:MM
    modifiedAt*: Time         ## File modification time
    content*: string          ## Rendered HTML content
    tags*: seq[TagInfo]       ## Tags this post belongs to

  MenuItem* = object
    ## Navigation entry for menus.
    url*: string              ## Link target, empty for text-only items
    label*: string            ## Display text
    active*: bool             ## True if this is the current page
    children*: seq[MenuItem]  ## Nested submenu items

  PostPreview* = object
    ## Truncated post content for list pages.
    slug*: string             ## Post identifier
    preview*: string          ## HTML up to read-more marker
    url*: string              ## Link to full post
    date*: Time               ## Post date
    dateHasTime*: bool        ## True if source included time
    tags*: seq[TagInfo]       ## Associated tags

  PageLink* = object
    ## Pagination link for list navigation.
    page*: int      ## Page number (1-indexed)
    url*: string    ## Link to page
    current*: bool  ## True if this is the active page
    ellipsis*: bool ## True for "..." gap placeholder

proc toTagSlug*(s: string): string =
  ## Normalize to lowercase-hyphenated: "How To" -> "how-to".
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
  ## Convert slug to title case: "how-to" -> "How To".
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
  ## Load BLG_BASE_URL, BLG_SITE_TITLE, BLG_SITE_DESCRIPTION from env.
  result.baseUrl = getEnv("BLG_BASE_URL", "").strip(chars = {'/'})
  result.siteTitle = getEnv("BLG_SITE_TITLE", "")
  result.siteDescription = getEnv("BLG_SITE_DESCRIPTION", "")
