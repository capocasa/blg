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

proc markdown*(text: string): string =
  ## Convert markdown to HTML using margrave
  let elements = parseMargrave(text)
  result = elements.join("\n")
