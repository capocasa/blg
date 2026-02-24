## Markdown rendering with caching and template application

import std/[os, times, strutils]
import md, types

proc formatDate*(t: Time): string =
  t.local.format("yyyy-MM-dd")

include "templates/page.nimf"
include "templates/post.nimf"
include "templates/list.nimf"

proc renderMarkdown*(path: string, cacheDir: string, force = false): tuple[content: string, changed: bool] =
  ## Render markdown to HTML, using cache if source is unmodified
  ## Returns content and whether it was re-rendered
  ## If force=true, always re-render regardless of cache
  let cachePath = cacheDir / path.splitFile.name & ".html"
  let srcMtime = getFileInfo(path).lastWriteTime

  if not force and fileExists(cachePath):
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

proc renderPage*(src: SourceFile, menu: seq[MenuItem]): string =
  pageTemplate(src.title, src.content, src.createdAt, src.modifiedAt, menu)

proc renderPost*(src: SourceFile, menu: seq[MenuItem]): string =
  postTemplate(src.title, src.content, src.createdAt, src.modifiedAt, menu)

proc renderList*(title: string, posts: seq[SourceFile], menu: seq[MenuItem], page, totalPages: int, urlSuffix = ".html"): string =
  var previews: seq[PostPreview]
  for post in posts:
    previews.add(PostPreview(
      title: post.title,
      preview: extractPreview(post.content),
      url: post.title & urlSuffix,
      date: post.createdAt
    ))
  listTemplate(title, previews, menu, page, totalPages)
