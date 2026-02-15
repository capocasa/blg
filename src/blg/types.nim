## Common types for blg

import std/times

type
  SourceFile* = object
    path*: string
    title*: string
    createdAt*: Time
    modifiedAt*: Time
    content*: string  # Rendered HTML content
