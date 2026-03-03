## Markdown rendering with caching and template application
## Handles date extraction, HTML caching, link processing, and page generation.
## See `blg <blg.html>`_ for template override instructions.

import std/[os, times, strutils, options]
import md, types, datetime, dynload

var helperLib*: TemplateLib  ## Set by blg.nim to enable template overrides

proc isIsoDate*(line: string): bool =
  ## True if line starts with YYYY-MM-DD, optionally with HH:MM[:SS].
  let s = line.strip
  if s.len < 10: return false
  # Check format: 4 digits, hyphen, 2 digits, hyphen, 2 digits
  if s.len >= 10 and
     s[0].isDigit and s[1].isDigit and s[2].isDigit and s[3].isDigit and
     s[4] == '-' and
     s[5].isDigit and s[6].isDigit and
     s[7] == '-' and
     s[8].isDigit and s[9].isDigit:
    # Date only - must be end of line or followed by whitespace
    if s.len == 10:
      return true
    # Must have whitespace after date
    if s[10] notin Whitespace:
      return false
    # Check for optional time HH:MM
    if s.len >= 16:
      let timeStart = 11
      if s[timeStart].isDigit and s[timeStart+1].isDigit and
         s[timeStart+2] == ':' and
         s[timeStart+3].isDigit and s[timeStart+4].isDigit:
        # HH:MM format - check if end or has seconds
        if s.len == 16:
          return true
        if s[16] in Whitespace:
          return true
        # Check for seconds :SS
        if s.len >= 19 and s[16] == ':' and
           s[17].isDigit and s[18].isDigit:
          return s.len == 19 or s[19] in Whitespace
        return false
    # Just date followed by whitespace (no valid time)
    return true
  false

proc extractIsoDate*(content: string): Option[(Time, bool)] =
  ## Parse date from first line; returns (Time, hasTime) or none.
  var i = 0
  while i < content.len and content[i] in Whitespace:
    inc i

  var lineEnd = i
  while lineEnd < content.len and content[lineEnd] notin {'\n', '\r'}:
    inc lineEnd

  let firstLine = content[i..<lineEnd].strip
  if not isIsoDate(firstLine):
    return none((Time, bool))

  try:
    # Try parsing with time (HH:MM:SS)
    if firstLine.len >= 19 and firstLine[10] in Whitespace and firstLine[13] == ':' and firstLine[16] == ':':
      let dateTimeStr = firstLine[0..9] & " " & firstLine[11..18]
      return some((parse(dateTimeStr, "yyyy-MM-dd HH:mm:ss").toTime, true))
    # Try parsing with time (HH:MM)
    if firstLine.len >= 16 and firstLine[10] in Whitespace and firstLine[13] == ':':
      let dateTimeStr = firstLine[0..9] & " " & firstLine[11..15]
      return some((parse(dateTimeStr, "yyyy-MM-dd HH:mm").toTime, true))
    # Date only
    let dateStr = firstLine[0..9]  # YYYY-MM-DD
    result = some((parse(dateStr, "yyyy-MM-dd").toTime, false))
  except:
    result = none((Time, bool))

proc stripDateLine*(content: string): string =
  ## Remove leading ISO date line before markdown rendering.
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

proc formatDate*(t: Time, hasTime = false): string =
  ## Format date, appending time if hasTime is true.
  result = formatTime(t)
  if hasTime:
    let dt = t.local
    # Check if seconds are non-zero to decide format
    if dt.second != 0:
      result &= " " & dt.format("HH:mm:ss")
    else:
      result &= " " & dt.format("HH:mm")

proc generatePageLinks*(listSlug: string, current, total: int, urlSuffix = ".html"): seq[PageLink] =
  ## Generate pagination with ellipsis for large page counts.
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

proc extractFirstImage*(html: string): string =
  ## Return src of first <img> tag in HTML, or empty string.
  let imgStart = html.find("<img ")
  if imgStart < 0:
    return ""
  let srcStart = html.find("src=\"", imgStart)
  if srcStart < 0:
    return ""
  let urlStart = srcStart + 5
  let urlEnd = html.find("\"", urlStart)
  if urlEnd < 0:
    return ""
  html[urlStart..<urlEnd]

const
  bgImageExts = [".jpg", ".jpeg", ".png", ".webp"]
  bgVideoExts = [".mp4", ".webm"]

proc resolveBackground*(slug: string, tags: seq[TagInfo], pageType: string,
                        outputDir: string, config: SiteConfig): tuple[image, video: string] =
  ## Cascade: slug > tag > type (page/post/tag) > site-wide.
  ## Returns filenames (empty string = not found).
  # 1. Slug-specific
  for ext in bgImageExts:
    if fileExists(outputDir / "background-" & slug & ext):
      result.image = "background-" & slug & ext
      break
  for ext in bgVideoExts:
    if fileExists(outputDir / "background-" & slug & ext):
      result.video = "background-" & slug & ext
      break
  if result.image.len > 0 or result.video.len > 0:
    return
  # 2. Tag-specific (first matching tag wins)
  for tag in tags:
    for ext in bgImageExts:
      if fileExists(outputDir / "background-" & tag.slug & ext):
        result.image = "background-" & tag.slug & ext
        break
    for ext in bgVideoExts:
      if fileExists(outputDir / "background-" & tag.slug & ext):
        result.video = "background-" & tag.slug & ext
        break
    if result.image.len > 0 or result.video.len > 0:
      return
  # 3. Type-specific (page/post/tag)
  if pageType.len > 0:
    for ext in bgImageExts:
      if fileExists(outputDir / "background-" & pageType & ext):
        result.image = "background-" & pageType & ext
        break
    for ext in bgVideoExts:
      if fileExists(outputDir / "background-" & pageType & ext):
        result.video = "background-" & pageType & ext
        break
    if result.image.len > 0 or result.video.len > 0:
      return
  # 4. Site-wide fallback
  result.image = config.backgroundImage
  result.video = config.backgroundVideo

proc renderBackground*(bg: tuple[image, video: string]): tuple[bodyStyle, bodyInsert: string] =
  ## Returns (inline style for <body>, HTML to insert after <body>).
  ## Video gets a fixed <video> element; image gets a CSS background on body.
  if bg.video.len > 0:
    var videoTag = "<video autoplay muted loop playsinline style=\"position:fixed;inset:0;width:100%;height:100%;object-fit:cover;z-index:-1\""
    if bg.image.len > 0:
      videoTag &= " poster=\"" & bg.image & "\""
    videoTag &= "><source src=\"" & bg.video & "\""
    # Determine type from extension
    if bg.video.endsWith(".webm"):
      videoTag &= " type=\"video/webm\""
    else:
      videoTag &= " type=\"video/mp4\""
    videoTag &= "></video>"
    result.bodyInsert = videoTag
  elif bg.image.len > 0:
    result.bodyStyle = "background:url(" & bg.image & ") center/cover no-repeat fixed"

proc renderScopedAssets*(slug: string, tags: seq[TagInfo], pageType: string,
                         outputDir: string): string =
  ## Return <link>/<script> tags for type, tag, and slug-scoped CSS/JS.
  ## Load order: type (broadest) > tag > slug (most specific).
  var seen: seq[string]
  # 1. Type-level (page/post/tag)
  if pageType.len > 0:
    let typeCss = pageType & ".css"
    if fileExists(outputDir / typeCss):
      result &= "  <link rel=\"stylesheet\" href=\"" & typeCss & "\">\n"
      seen.add(typeCss)
    let typeJs = pageType & ".js"
    if fileExists(outputDir / typeJs):
      result &= "  <script src=\"" & typeJs & "\"></script>\n"
      seen.add(typeJs)
  # 2. Tag-level
  for tag in tags:
    let cssFile = tag.slug & ".css"
    if fileExists(outputDir / cssFile) and cssFile notin seen:
      result &= "  <link rel=\"stylesheet\" href=\"" & cssFile & "\">\n"
      seen.add(cssFile)
    let jsFile = tag.slug & ".js"
    if fileExists(outputDir / jsFile) and jsFile notin seen:
      result &= "  <script src=\"" & jsFile & "\"></script>\n"
      seen.add(jsFile)
  # 3. Slug-level
  let slugCss = slug & ".css"
  if fileExists(outputDir / slugCss) and slugCss notin seen:
    result &= "  <link rel=\"stylesheet\" href=\"" & slugCss & "\">\n"
  let slugJs = slug & ".js"
  if fileExists(outputDir / slugJs) and slugJs notin seen:
    result &= "  <script src=\"" & slugJs & "\"></script>\n"

proc resolveOgImage*(content: string, config: SiteConfig): string =
  ## Best OG image: first image in content, else site-wide og-image, else empty.
  ## Returns absolute URL or empty string.
  if config.baseUrl.len == 0:
    return ""
  let firstImg = extractFirstImage(content)
  if firstImg.len > 0:
    if firstImg.startsWith("http://") or firstImg.startsWith("https://"):
      return firstImg
    return config.baseUrl & "/" & firstImg
  if config.ogImage.len > 0:
    return config.baseUrl & "/" & config.ogImage
  ""

include "templates/helpers.nimf"

# Dispatch procs - check dynlib override, fallback to builtin
proc renderMenuItem(item: MenuItem): string =
  if helperLib.renderMenuItem != nil:
    helperLib.renderMenuItem(item)
  else:
    builtinRenderMenuItem(item)

proc renderHead(fullTitle: string, config: SiteConfig): string =
  if helperLib.renderHead != nil:
    helperLib.renderHead(fullTitle, config)
  else:
    builtinRenderHead(fullTitle, config)

proc renderTopNav(topMenu: seq[MenuItem]): string =
  if helperLib.renderTopNav != nil:
    helperLib.renderTopNav(topMenu)
  else:
    builtinRenderTopNav(topMenu)

proc renderSiteHeader(config: SiteConfig): string =
  if helperLib.renderSiteHeader != nil:
    helperLib.renderSiteHeader(config)
  else:
    builtinRenderSiteHeader(config)

proc renderFooter(bottomMenu: seq[MenuItem], hasMultipleMenus: bool): string =
  if helperLib.renderFooter != nil:
    helperLib.renderFooter(bottomMenu, hasMultipleMenus)
  else:
    builtinRenderFooter(bottomMenu, hasMultipleMenus)

proc renderOgTags(title, description, url, image: string): string =
  builtinRenderOgTags(title, description, url, image)

include "templates/page.nimf"
include "templates/post.nimf"
include "templates/list.nimf"

proc renderMarkdown*(path: string, cacheDir: string, force = false): tuple[content: string, changed: bool] =
  ## Render markdown to HTML with caching; returns (html, wasRerendered).
  let cachePath = cacheDir / path.splitFile.name & ".html"
  let srcMtime = getFileInfo(path).lastWriteTime

  if not force and fileExists(cachePath):
    let cacheMtime = getFileInfo(cachePath).lastWriteTime
    if cacheMtime > srcMtime:
      return (readFile(cachePath), false)

  let content = readFile(path).stripDateLine.insertReadMoreMarker
  let rendered = markdown(content)
  createDir(cacheDir)
  writeFile(cachePath, rendered)
  (rendered, true)

proc linkFirstH1*(content: string, url: string): string =
  ## Wrap first <h1> content in a link for clickable post titles.
  let h1Start = content.find("<h1>")
  if h1Start < 0:
    return content
  let h1End = content.find("</h1>", h1Start)
  if h1End < 0:
    return content
  let tagEnd = h1Start + 4  # after "<h1>"
  let inner = content[tagEnd..<h1End]
  result = content[0..<tagEnd] & "<a href=\"" & url & "\">" & inner & "</a>" & content[h1End..^1]

proc closeUnclosedTags(html: string): string =
  ## Append closing tags for any unclosed HTML elements.
  ## Prevents bold/italic/link leaking when preview is truncated mid-tag.
  var openTags: seq[string]
  var i = 0
  while i < html.len:
    if html[i] == '<':
      let tagStart = i + 1
      if tagStart < html.len and html[tagStart] == '/':
        # Closing tag: extract name and pop from stack
        let nameStart = tagStart + 1
        var nameEnd = nameStart
        while nameEnd < html.len and html[nameEnd] notin {'>', ' ', '\t', '\n'}:
          inc nameEnd
        let name = html[nameStart..<nameEnd].toLowerAscii
        # Pop the matching open tag (search from top)
        for j in countdown(openTags.high, 0):
          if openTags[j] == name:
            openTags.delete(j)
            break
      elif tagStart < html.len and html[tagStart] != '!':
        # Opening tag: extract name
        var nameEnd = tagStart
        while nameEnd < html.len and html[nameEnd] notin {'>', ' ', '\t', '\n', '/'}:
          inc nameEnd
        let name = html[tagStart..<nameEnd].toLowerAscii
        # Skip self-closing and void elements
        let voids = ["br", "hr", "img", "input", "meta", "link", "read-more"]
        if name notin voids:
          # Check for self-closing />
          var closePos = nameEnd
          while closePos < html.len and html[closePos] != '>':
            inc closePos
          if closePos > 0 and html[closePos - 1] != '/':
            openTags.add(name)
      # Skip to end of tag
      while i < html.len and html[i] != '>':
        inc i
    inc i
  # Close remaining open tags in reverse order
  for j in countdown(openTags.high, 0):
    result.add("</" & openTags[j] & ">")
  result = html & result

proc extractPreview*(content: string): string =
  ## Return content up to <read-more/> or first </p>.
  let marker = "<read-more/>"
  let markerPos = content.find(marker)
  if markerPos >= 0:
    result = closeUnclosedTags(content[0..<markerPos])
  else:
    # Take first paragraph if no marker found
    let pEnd = content.find("</p>")
    if pEnd >= 0:
      result = content[0..pEnd+3]
    else:
      result = content

proc isExternalUrl(url: string, baseUrl: string): bool =
  ## True if URL points to a different domain.
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
  ## Rewrite relative URLs to absolute; mark external links with target="_blank".
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

      # Handle "." (current directory) specially for index/home links
      if url == ".":
        if config.baseUrl.len > 0:
          # With baseUrl, convert "." to "baseUrl/"
          let absoluteUrl = config.baseUrl & "/"
          result = result[0..<urlStart] & absoluteUrl & result[urlEnd..^1]
          i = urlStart + absoluteUrl.len + 1
        else:
          # Without baseUrl, leave "." as-is
          i = urlEnd + 1
        continue

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
  ## Render a static page (no date/tags shown).
  pageTemplate(src.title, src.content, src.createdAt, src.modifiedAt, menus, config).processLinks(config)

proc renderPost*(src: SourceFile, menus: seq[seq[MenuItem]], config: SiteConfig): string =
  ## Render a blog post with date and tags.
  postTemplate(src.title, src.content, src.createdAt, src.modifiedAt, src.createdAtHasTime, menus, src.tags, config).processLinks(config)

proc renderList*(listTitle: string, posts: seq[SourceFile], menus: seq[seq[MenuItem]], page, totalPages: int, urlSuffix = ".html", config: SiteConfig): string =
  ## Render paginated post list for index or tag pages.
  var previews: seq[PostPreview]
  for post in posts:
    let url = post.slug & urlSuffix
    previews.add(PostPreview(
      slug: post.slug,
      preview: extractPreview(post.content),
      url: url,
      date: post.createdAt,
      dateHasTime: post.createdAtHasTime,
      tags: post.tags
    ))
  listTemplate(listTitle, previews, menus, page, totalPages, urlSuffix, config).processLinks(config)

proc stripHtmlTags(html: string): string =
  ## Remove HTML tags, leaving plain text.
  var inTag = false
  for c in html:
    if c == '<':
      inTag = true
    elif c == '>':
      inTag = false
    elif not inTag:
      result.add(c)

proc toRfc822(t: Time): string =
  ## Format time as RFC 822 for RSS pubDate.
  t.utc.format("ddd, dd MMM yyyy HH:mm:ss") & " +0000"

proc xmlEscape(s: string): string =
  ## Escape special characters for XML content.
  for c in s:
    case c
    of '&': result.add("&amp;")
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '"': result.add("&quot;")
    else: result.add(c)

proc generateRssFeed*(posts: seq[SourceFile], config: SiteConfig, urlSuffix: string): string =
  ## Generate RSS 2.0 XML feed from posts. Requires baseUrl.
  var items = ""
  let count = min(posts.len, 20)
  for i in 0..<count:
    let post = posts[i]
    let link = config.baseUrl & "/" & post.slug & urlSuffix
    var preview = extractPreview(post.content)
    # Strip H1 heading from preview (title is already in <title>)
    let h1End = preview.find("</h1>")
    if h1End >= 0:
      preview = preview[h1End + 5..^1]
    preview = preview.stripHtmlTags.strip.xmlEscape
    items.add("    <item>\n")
    items.add("      <title>" & post.title.xmlEscape & "</title>\n")
    items.add("      <link>" & link & "</link>\n")
    items.add("      <description>" & preview & "</description>\n")
    items.add("      <pubDate>" & post.createdAt.toRfc822 & "</pubDate>\n")
    items.add("      <guid>" & link & "</guid>\n")
    items.add("    </item>\n")

  result = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>""" & config.siteTitle.xmlEscape & """</title>
    <link>""" & config.baseUrl & """</link>
    <description>""" & config.siteDescription.xmlEscape & """</description>
""" & items & """  </channel>
</rss>
"""

proc generateSitemap*(sources: seq[SourceFile], tagSlugs: seq[string], config: SiteConfig, urlSuffix: string): string =
  ## Generate XML sitemap. Requires baseUrl.
  var urls = ""
  for src in sources:
    let loc = config.baseUrl & "/" & src.slug & urlSuffix
    urls.add("  <url><loc>" & loc & "</loc></url>\n")
  # Index page
  urls.add("  <url><loc>" & config.baseUrl & "/index" & urlSuffix & "</loc></url>\n")
  # Tag pages
  for slug in tagSlugs:
    urls.add("  <url><loc>" & config.baseUrl & "/" & slug & urlSuffix & "</loc></url>\n")

  result = """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
""" & urls & """</urlset>
"""
