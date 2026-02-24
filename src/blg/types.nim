## Common types for blg

import std/times

type
  SourceFile* = object
    path*: string
    title*: string
    createdAt*: Time
    modifiedAt*: Time
    content*: string  # Rendered HTML content

  # Template interface types
  MenuItem* = object
    url*, label*: string
    active*: bool

  PostPreview* = object
    title*, preview*, url*: string
    date*: Time
