## Markdown to HTML using nmark (CommonMark + GFM tables)
## Handles title extraction, read-more markers, and rendering.

import nmark
import std/strutils
import types

proc extractMarkdownTitle*(text: string): string =
  ## Return text of first H1 heading, or empty string if none.
  for line in text.splitLines:
    let trimmed = line.strip
    if trimmed.startsWith("# "):
      return trimmed[2..^1].strip
  return ""

proc insertReadMoreMarker*(text: string): string =
  ## Insert <read-more/> at first triple-newline break for post previews.
  var i = 0
  var foundParagraph = false

  while i < text.len:
    # Track if we've seen content (a paragraph)
    if not foundParagraph and text[i] notin {'\n', '\r', ' ', '\t'}:
      foundParagraph = true

    # Look for 3+ consecutive newlines
    if text[i] == '\n':
      var newlineCount = 0
      var j = i
      while j < text.len and text[j] in {'\n', '\r'}:
        if text[j] == '\n':
          inc newlineCount
        inc j

      if newlineCount >= 3 and foundParagraph:
        # Insert marker inline at end of previous content
        return text[0..<i] & "<read-more/>\n\n" & text[j..^1]

      i = j
    else:
      inc i

  text

proc extractMarkdownLinks*(text: string): seq[MarkdownLink] =
  ## Extract [text](url) links from markdown source, skipping images and code blocks.
  var lineNum = 0
  var inFencedCode = false
  for line in text.splitLines:
    inc lineNum
    let trimmed = line.strip
    # Track fenced code blocks
    if trimmed.startsWith("```") or trimmed.startsWith("~~~"):
      inFencedCode = not inFencedCode
      continue
    if inFencedCode:
      continue
    var i = 0
    while i < line.len:
      # Skip inline code spans
      if line[i] == '`':
        inc i
        while i < line.len and line[i] != '`':
          inc i
        if i < line.len: inc i
        continue
      # Look for [text](url) but not ![alt](url)
      if line[i] == '[' and (i == 0 or line[i-1] != '!'):
        let bracketStart = i
        inc i
        # Find closing ]
        var depth = 1
        while i < line.len and depth > 0:
          if line[i] == '[': inc depth
          elif line[i] == ']': dec depth
          inc i
        # Check for ( immediately after ]
        if i < line.len and line[i] == '(':
          inc i
          let urlStart = i
          # Find closing ), handling possible "title"
          var parenDepth = 1
          while i < line.len and parenDepth > 0:
            if line[i] == '(': inc parenDepth
            elif line[i] == ')': dec parenDepth
            inc i
          let urlEnd = i - 1  # before closing )
          var url = line[urlStart..<urlEnd].strip
          # Strip optional title in quotes
          let quotePos = url.find('"')
          if quotePos > 0:
            url = url[0..<quotePos].strip
          # Skip external, anchor-only, mailto, data URLs
          if url.len > 0 and
             not url.startsWith("http://") and not url.startsWith("https://") and
             not url.startsWith("mailto:") and not url.startsWith("data:") and
             url[0] != '#':
            result.add(MarkdownLink(url: url, line: lineNum))
      else:
        inc i

func autolinkUrls*(text: string): string =
  ## Wrap bare http(s) URLs in angle brackets so nmark's built-in inline
  ## autolink renders them as <a> tags with the URL as both text and href.
  ## Skips fenced code blocks, inline code spans, markdown link/image
  ## destinations, and HTML tags.
  const schemes = ["http://", "https://"]
  const trailingPunct = {',', ';', ':', '!', '?', '"'}

  func parensBalanced(s: string): bool =
    var depth = 0
    for c in s:
      if c == '(': inc depth
      elif c == ')': dec depth
      if depth < 0: return false
    depth == 0

  func precededOk(line: string, pos: int): bool =
    ## URL must start a line or follow whitespace/punctuation, and must
    ## not be glued to a word char (xhttps:// is not a link).
    if pos == 0: true
    else: line[pos - 1] in {' ', '\t', '(', '<', '*', '~', '>'}

  func findUrlEnd(line: string, start: int): int =
    ## URL ends at whitespace or an opening angle bracket/quote.
    var k = start
    while k < line.len and line[k] notin {' ', '\t', '<', '>'}:
      inc k
    k

  func trimTrailing(url: string): string =
    ## Drop sentence punctuation from the end of a URL. A closing paren
    ## only goes if the remaining URL has balanced parens, so
    ## https://ex.com/a_(b) keeps its parens while (see https://ex.com)
    ## does not drag the paren into the href.
    var u = url
    while u.len > 0:
      let last = u[^1]
      if last in trailingPunct:
        u = u[0 ..< ^1]
      elif last == ')':
        if parensBalanced(u[0 ..< ^1]): u = u[0 ..< ^1]
        else: break
      elif last == '.':
        # Keep a trailing dot only if stripping it leaves another trailing
        # dot or nothing sensible; standard behavior is to strip.
        u = u[0 ..< ^1]
      else:
        break
    u

  result = ""
  var i = 0
  var inFencedCode = false
  var inHtmlBlock = false
  while i < text.len:
    let rest = text[i .. ^1]
    let nl = rest.find('\n')
    let line = if nl >= 0: rest[0 ..< nl] else: rest
    i += line.len
    if i < text.len: inc i  # consume newline

    if inHtmlBlock:
      if line.strip.len == 0: inHtmlBlock = false
      result.add line
      if i <= text.len and text[i - 1] == '\n': result.add '\n'
      continue
    let stripped = line.strip
    if stripped.startsWith("```") or stripped.startsWith("~~~"):
      inFencedCode = not inFencedCode
      result.add line
      if i <= text.len and text[i - 1] == '\n': result.add '\n'
      continue
    if inFencedCode:
      result.add line
      if i <= text.len and text[i - 1] == '\n': result.add '\n'
      continue
    # CommonMark HTML block: a line starting with a tag is raw HTML until
    # a blank line, so leave it untouched (urls inside stay literal).
    if stripped.len > 1 and stripped[0] == '<' and
       stripped[1] in {'a'..'z', 'A'..'Z', '/', '!'}:
      inHtmlBlock = true
      result.add line
      if i <= text.len and text[i - 1] == '\n': result.add '\n'
      continue

    var j = 0
    var outLine = ""
    while j < line.len:
      let c = line[j]
      # Inline code span: copy verbatim through the matching closer
      if c == '`':
        var ticks = 0
        while j < line.len and line[j] == '`':
          inc ticks
          inc j
        outLine.add repeat('`', ticks)
        while j < line.len:
          if line[j] == '`':
            var closer = 0
            while j + closer < line.len and line[j + closer] == '`':
              inc closer
            if closer == ticks:
              outLine.add repeat('`', ticks)
              inc j, ticks
              break
            outLine.add line[j]
            inc j
          else:
            outLine.add line[j]
            inc j
        continue
      # Link text: copy [ ... ]( verbatim when it starts an inline link.
      # Autolinking inside link text would nest an <a> inside an <a>.
      if c == '[' and (j == 0 or line[j - 1] != '!') and
         line.find("](", j) >= 0:
        let close = line.find("](", j)
        outLine.add line[j ..< close]
        j = close
        continue
      # Markdown link/image destination: ]( ... ) copied verbatim
      if c == ']' and j + 1 < line.len and line[j + 1] == '(':
        var depth = 0
        while j < line.len:
          if line[j] == '(': inc depth
          elif line[j] == ')': dec depth
          outLine.add line[j]
          inc j
          if depth == 0: break
        continue
      # HTML tag: <div ...>, </p>, <!-- comment --> copied verbatim
      if c == '<' and j + 1 < line.len and
         line[j + 1] in {'a'..'z', 'A'..'Z', '/', '!'}:
        while j < line.len:
          outLine.add line[j]
          if line[j] == '>': break
          inc j
        inc j
        continue
      # Bare URL
      var matched = false
      for scheme in schemes:
        if line.continuesWith(scheme, j) and precededOk(line, j):
          let urlEnd = findUrlEnd(line, j)
          var url = trimTrailing(line[j ..< urlEnd])
          # Require at least a scheme plus one char
          if url.len > scheme.len:
            outLine.add '<' & url & '>'
            inc j, url.len
            matched = true
          break
      if not matched:
        outLine.add c
        inc j
    result.add outLine
    if i <= text.len and text[i - 1] == '\n': result.add '\n'

proc markdown*(text: string): string =
  ## Convert markdown source to HTML via nmark parser, with bare URLs
  ## autolinked (text and href are the same URL).
  ## Qualified call: a bare `text.markdown` would resolve to this proc
  ## itself (same name) and recurse infinitely.
  ## nmark terminates blocks with "\p", which is CRLF on Windows;
  ## normalize so output is identical on every platform.
  result = nmark.markdown(autolinkUrls(text)).replace("\c\l", "\n")
