## Markdown to HTML using margrave (pure Nim)

import margrave
import std/strutils

proc extractMarkdownTitle*(text: string): string =
  ## Extract the first # heading from markdown source
  for line in text.splitLines:
    let trimmed = line.strip
    if trimmed.startsWith("# "):
      return trimmed[2..^1].strip
  return ""

proc insertReadMoreMarker*(text: string): string =
  ## Insert <!-- readmore --> at first 3+ consecutive newlines
  ## Ensures at least one paragraph exists before the marker
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

proc markdown*(text: string): string =
  ## Convert markdown to HTML using margrave
  let elements = parseMargrave(text)
  result = elements.join("\n")
