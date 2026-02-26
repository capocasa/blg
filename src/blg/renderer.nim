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

proc isExternalUrl(url: string, baseUrl: string): bool =
  ## Check if URL is external (not relative, not starting with baseUrl)
  if url.len == 0 or url[0] == '#':
    return false  # anchor link
  if url[0] == '/':
    return false  # root-relative (internal)
  if not url.startsWith("http://") and not url.startsWith("https://"):
    return false  # relative path (internal)
  if baseUrl.len > 0 and url.startsWith(baseUrl):
    return false  # matches our base URL (internal)
  return true

proc processLinks*(html: string, config: SiteConfig): string =
  ## Post-process HTML to:
  ## 1. Convert root-relative URLs to absolute when baseUrl is set
  ## 2. Mark external links with class="external", target="_blank", rel="noopener noreferrer"
  result = html

  if config.baseUrl.len == 0:
    # No base URL - only process external links in href (not src)
    # Look for <a with href="http(s)://..." that doesn't match any base
    var i = 0
    while i < result.len:
      let aStart = result.find("<a ", i)
      if aStart < 0:
        break
      let aEnd = result.find(">", aStart)
      if aEnd < 0:
        break

      # Extract the <a ...> tag
      let tag = result[aStart..aEnd]
      let hrefStart = tag.find("href=\"")
      if hrefStart >= 0:
        let urlStart = hrefStart + 6
        let urlEnd = tag.find("\"", urlStart)
        if urlEnd > urlStart:
          let url = tag[urlStart..<urlEnd]
          if isExternalUrl(url, ""):
            # Add external link attributes
            var newTag = tag
            # Add class
            let classPos = newTag.find("class=\"")
            if classPos >= 0:
              let classInsert = classPos + 7
              newTag = newTag[0..<classInsert] & "external " & newTag[classInsert..^1]
            else:
              newTag = newTag[0..1] & " class=\"external\"" & newTag[2..^1]
            # Add target and rel if not present
            if not newTag.contains("target="):
              newTag = newTag[0..^2] & " target=\"_blank\">"
            if not newTag.contains("rel="):
              newTag = newTag[0..^2] & " rel=\"noopener noreferrer\">"
            result = result[0..<aStart] & newTag & result[aEnd+1..^1]
            i = aStart + newTag.len
            continue

      i = aEnd + 1
  else:
    # Have base URL - process both root-relative and external links
    var i = 0
    while i < result.len:
      # Find href=" or src="
      let hrefPos = result.find("href=\"", i)
      let srcPos = result.find("src=\"", i)

      var attrPos = -1
      var attrLen = 0
      var isHref = false

      if hrefPos >= 0 and (srcPos < 0 or hrefPos < srcPos):
        attrPos = hrefPos
        attrLen = 6  # len of href="
        isHref = true
      elif srcPos >= 0:
        attrPos = srcPos
        attrLen = 5  # len of src="
        isHref = false

      if attrPos < 0:
        break

      let urlStart = attrPos + attrLen
      let urlEnd = result.find("\"", urlStart)
      if urlEnd < 0:
        i = urlStart
        continue

      let url = result[urlStart..<urlEnd]

      # Convert relative URLs to absolute (both /path and path.html forms)
      if url.len > 0 and url[0] notin {'#', '/'} and
         not url.startsWith("http://") and not url.startsWith("https://") and
         not url.startsWith("mailto:") and not url.startsWith("data:"):
        # Relative path like "index.html" -> "https://base.url/index.html"
        let absoluteUrl = config.baseUrl & "/" & url
        result = result[0..<urlStart] & absoluteUrl & result[urlEnd..^1]
        i = urlStart + absoluteUrl.len + 1
        continue

      if url.len > 0 and url[0] == '/':
        # Root-relative path like "/path" -> "https://base.url/path"
        let absoluteUrl = config.baseUrl & url
        result = result[0..<urlStart] & absoluteUrl & result[urlEnd..^1]
        i = urlStart + absoluteUrl.len + 1
        continue

      # Mark external links (only for href, not src)
      if isHref and isExternalUrl(url, config.baseUrl):
        # Find the <a tag start
        var tagStart = attrPos
        while tagStart > 0 and result[tagStart] != '<':
          dec tagStart
        if tagStart >= 0 and result[tagStart..<tagStart+3] == "<a ":
          let tagEnd = result.find(">", attrPos)
          if tagEnd > attrPos:
            var tag = result[tagStart..tagEnd]
            var modified = false

            # Add class
            let classPos = tag.find("class=\"")
            if classPos >= 0:
              let classInsert = classPos + 7
              tag = tag[0..<classInsert] & "external " & tag[classInsert..^1]
              modified = true
            else:
              # Insert after <a
              tag = tag[0..1] & " class=\"external\"" & tag[2..^1]
              modified = true

            # Add target and rel if not present
            if not tag.contains("target="):
              tag = tag[0..^2] & " target=\"_blank\">"
              modified = true
            if not tag.contains("rel="):
              tag = tag[0..^2] & " rel=\"noopener noreferrer\">"
              modified = true

            if modified:
              result = result[0..<tagStart] & tag & result[tagEnd+1..^1]
              i = tagStart + tag.len
              continue

      i = urlEnd + 1

proc renderPage*(src: SourceFile, menus: seq[seq[MenuItem]], config: SiteConfig): string =
  pageTemplate(src.title, src.content, src.createdAt, src.modifiedAt, menus, config).processLinks(config)

proc renderPost*(src: SourceFile, menus: seq[seq[MenuItem]], config: SiteConfig): string =
  postTemplate(src.title, src.content, src.createdAt, src.modifiedAt, menus, src.tags, config).processLinks(config)

proc renderList*(listTitle: string, posts: seq[SourceFile], menus: seq[seq[MenuItem]], page, totalPages: int, urlSuffix = ".html", config: SiteConfig): string =
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
  listTemplate(listTitle, previews, menus, page, totalPages, urlSuffix, config).processLinks(config)
