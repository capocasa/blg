## Markdown rendering with caching and template application

import std/[os, times, strutils, options]
import md, types, datetime

proc isIsoDate*(line: string): bool =
  ## Check if line matches YYYY-MM-DD format
  let s = line.strip
  if s.len < 10: return false
  # Check format: 4 digits, hyphen, 2 digits, hyphen, 2 digits
  if s.len >= 10 and
     s[0].isDigit and s[1].isDigit and s[2].isDigit and s[3].isDigit and
     s[4] == '-' and
     s[5].isDigit and s[6].isDigit and
     s[7] == '-' and
     s[8].isDigit and s[9].isDigit:
    # Must be end of line or followed by whitespace/newline
    return s.len == 10 or s[10] in Whitespace
  false

proc extractIsoDate*(content: string): Option[Time] =
  ## Extract ISO date from first line of content if present
  var i = 0
  while i < content.len and content[i] in Whitespace:
    inc i

  var lineEnd = i
  while lineEnd < content.len and content[lineEnd] notin {'\n', '\r'}:
    inc lineEnd

  let firstLine = content[i..<lineEnd].strip
  if not isIsoDate(firstLine):
    return none(Time)

  try:
    let dateStr = firstLine[0..9]  # YYYY-MM-DD
    result = some(parse(dateStr, "yyyy-MM-dd").toTime)
  except:
    result = none(Time)

proc stripDateLine*(content: string): string =
  ## Remove leading ISO date line from content (for rendering)
  # Skip leading whitespace
  var i = 0
  while i < content.len and content[i] in Whitespace:
    inc i

  # Find end of first line
  var lineEnd = i
  while lineEnd < content.len and content[lineEnd] notin {'\n', '\r'}:
    inc lineEnd

  let firstLine = content[i..<lineEnd]
  if not isIsoDate(firstLine):
    return content

  # Skip past the date line and any following whitespace
  i = lineEnd
  while i < content.len and content[i] in Whitespace:
    inc i

  content[i..^1]

proc ensureDateLine(path: string, mtime: Time): bool =
  ## Check if file starts with an ISO date, if not prepend mtime date.
  ## Returns true if file was modified.
  let content = readFile(path)

  # Find first non-whitespace line
  var firstLineStart = 0
  while firstLineStart < content.len and content[firstLineStart] in Whitespace:
    inc firstLineStart

  # Find end of first line
  var firstLineEnd = firstLineStart
  while firstLineEnd < content.len and content[firstLineEnd] notin {'\n', '\r'}:
    inc firstLineEnd

  let firstLine = if firstLineStart < content.len:
    content[firstLineStart..<firstLineEnd]
  else:
    ""

  if isIsoDate(firstLine):
    return false

  # Prepend ISO date
  let dateStr = mtime.format("yyyy-MM-dd")
  let newContent = dateStr & "\n\n" & content
  writeFile(path, newContent)
  true

proc formatDate*(t: Time): string =
  formatTime(t)

proc generatePageLinks*(listSlug: string, current, total: int, urlSuffix = ".html"): seq[PageLink] =
  ## Generate page links with smart truncation
  ## Shows: first, ellipsis, window around current, ellipsis, last
  if total <= 1:
    return @[]

  proc pageUrl(p: int): string =
    if p == 1: listSlug & urlSuffix
    else: listSlug & "-" & $p & urlSuffix

  var pages: seq[int]

  if total <= 7:
    # Show all pages if 7 or fewer
    for i in 1..total:
      pages.add(i)
  else:
    # Always show first page
    pages.add(1)

    # Window around current page (2 on each side)
    let windowStart = max(2, current - 2)
    let windowEnd = min(total - 1, current + 2)

    # Add ellipsis if gap after first
    if windowStart > 2:
      pages.add(-1)  # -1 = ellipsis

    for i in windowStart..windowEnd:
      pages.add(i)

    # Add ellipsis if gap before last
    if windowEnd < total - 1:
      pages.add(-1)

    # Always show last page
    pages.add(total)

  for p in pages:
    if p == -1:
      result.add(PageLink(ellipsis: true))
    else:
      result.add(PageLink(page: p, url: pageUrl(p), current: p == current))

include "templates/page.nimf"
include "templates/post.nimf"
include "templates/list.nimf"

proc renderMarkdown*(path: string, cacheDir: string, force = false): tuple[content: string, changed: bool] =
  ## Render markdown to HTML, using cache if source is unmodified
  ## Returns content and whether it was re-rendered
  ## If force=true, always re-render regardless of cache
  let cachePath = cacheDir / path.splitFile.name & ".html"
  let srcMtime = getFileInfo(path).lastWriteTime

  if not force and fileExists(cachePath):
    let cacheMtime = getFileInfo(cachePath).lastWriteTime
    if cacheMtime > srcMtime:
      return (readFile(cachePath), false)

  # Auto-add date if missing (in-place edit)
  discard ensureDateLine(path, srcMtime)

  let content = readFile(path).stripDateLine.insertReadMoreMarker
  let rendered = markdown(content)
  createDir(cacheDir)
  writeFile(cachePath, rendered)
  (rendered, true)

proc linkFirstH1*(content: string, url: string): string =
  ## Wrap the content of the first <h1> in a link to url
  let h1Start = content.find("<h1>")
  if h1Start < 0:
    return content
  let h1End = content.find("</h1>", h1Start)
  if h1End < 0:
    return content
  let tagEnd = h1Start + 4  # after "<h1>"
  let inner = content[tagEnd..<h1End]
  result = content[0..<tagEnd] & "<a href=\"" & url & "\">" & inner & "</a>" & content[h1End..^1]

proc extractPreview*(content: string): string =
  ## Extract content up to the read-more marker, falling back to first paragraph
  let marker = "<read-more/>"
  let markerPos = content.find(marker)
  if markerPos >= 0:
    result = content[0..<markerPos]
  else:
    # Take first paragraph if no marker found
    let pEnd = content.find("</p>")
    if pEnd >= 0:
      result = content[0..pEnd+3]
    else:
      result = content

proc renderPage*(src: SourceFile, menu: seq[MenuItem]): string =
  pageTemplate(src.slug, src.content, src.createdAt, src.modifiedAt, menu)

proc renderPost*(src: SourceFile, menu: seq[MenuItem]): string =
  postTemplate(src.slug, src.content, src.createdAt, src.modifiedAt, menu, src.tags)

proc renderList*(listTitle: string, posts: seq[SourceFile], menu: seq[MenuItem], page, totalPages: int, urlSuffix = ".html"): string =
  var previews: seq[PostPreview]
  for post in posts:
    let url = post.slug & urlSuffix
    previews.add(PostPreview(
      slug: post.slug,
      preview: linkFirstH1(extractPreview(post.content), url),
      url: url,
      date: post.createdAt,
      tags: post.tags
    ))
  listTemplate(listTitle, previews, menu, page, totalPages, urlSuffix)
