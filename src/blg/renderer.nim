## Markdown rendering with caching and template application

import std/[os, times, strutils]
import md, types

include "../templates/page.nimf"
include "../templates/post.nimf"
include "../templates/list.nimf"

proc renderMarkdown*(path: string, cacheDir: string): tuple[content: string, changed: bool] =
  ## Render markdown to HTML, using cache if source is unmodified
  ## Returns content and whether it was re-rendered
  let cachePath = cacheDir / path.splitFile.name & ".html"
  let srcMtime = getFileInfo(path).lastWriteTime

  if fileExists(cachePath):
    let cacheMtime = getFileInfo(cachePath).lastWriteTime
    if cacheMtime > srcMtime:
      return (readFile(cachePath), false)

  let content = readFile(path)
  let rendered = markdown(content)
  createDir(cacheDir)
  writeFile(cachePath, rendered)
  (rendered, true)

proc extractPreview*(content: string): string =
  ## Extract content up to the first horizontal rule (<hr>)
  let hrPatterns = ["<hr>", "<hr/>", "<hr />"]
  var minPos = content.len
  for pattern in hrPatterns:
    let pos = content.find(pattern)
    if pos >= 0 and pos < minPos:
      minPos = pos
  if minPos < content.len:
    result = content[0..<minPos]
  else:
    # Take first paragraph if no HR found
    let pEnd = content.find("</p>")
    if pEnd >= 0:
      result = content[0..pEnd+3]
    else:
      result = content

proc formatDate*(t: Time): string =
  t.local.format("yyyy-MM-dd")

proc renderPage*(src: SourceFile, menuItems: seq[string]): string =
  pageTemplate(src.title, src.content, menuItems, formatDate(src.createdAt), formatDate(src.modifiedAt))

proc renderPost*(src: SourceFile, menuItems: seq[string]): string =
  postTemplate(src.title, src.content, menuItems, formatDate(src.createdAt), formatDate(src.modifiedAt))

proc renderList*(name: string, posts: seq[SourceFile], menuItems: seq[string]): string =
  var items: seq[tuple[title, preview, url, date: string]]
  for post in posts:
    items.add((
      title: post.title,
      preview: extractPreview(post.content),
      url: post.title & ".html",
      date: formatDate(post.createdAt)
    ))
  listTemplate(name, items, menuItems)
