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

proc markdown*(text: string): string =
  ## Convert markdown source to HTML via nmark parser.
  ## Qualified call: a bare `text.markdown` would resolve to this proc
  ## itself (same name) and recurse infinitely.
  result = nmark.markdown(text)
