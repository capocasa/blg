## Common types for blg

import std/times

type
  SourceFile* = object
    path*: string
    slug*: string  # Filename without extension (for URLs)
    title*: string  # Display title extracted from content <h1>
    createdAt*: Time
    modifiedAt*: Time
    content*: string  # Rendered HTML content
    tags*: seq[string]  # Tags this post belongs to

  # Template interface types
  MenuItem* = object
    url*, label*: string
    active*: bool

  PostPreview* = object
    slug*, preview*, url*: string
    date*: Time
    tags*: seq[string]  # Tags for linking
