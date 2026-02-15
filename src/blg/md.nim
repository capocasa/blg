## Markdown to HTML using margrave (pure Nim)

import margrave
import std/strutils

proc markdown*(text: string): string =
  ## Convert markdown to HTML using margrave
  let elements = parseMargrave(text)
  result = elements.join("\n")
