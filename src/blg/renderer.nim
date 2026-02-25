## Markdown rendering with caching and template application

import std/[os, times, strutils]
import md, types, datetime

proc formatDate*(t: Time): string =
  formatTime(t)

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

proc linkFirstH1*(content: string, url: string): string =
  ## Wrap the content of the first <h1> in a link to url
  let h1Start = content.find("<h1>")
  if h1Start < 0:
    return content
  let h1End = content.find("</h1>", h1Start)
  if h1End < 0:
    return content
  let tagEnd = h1Start + 4  # after "<h1>"
  let inner = content[tagEnd..<h1End]
  result = content[0..<tagEnd] & "<a href=\"" & url & "\">" & inner & "</a>" & content[h1End..^1]

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
  pageTemplate(src.slug, src.content, src.createdAt, src.modifiedAt, menu)

proc renderPost*(src: SourceFile, menu: seq[MenuItem]): string =
  postTemplate(src.slug, src.content, src.createdAt, src.modifiedAt, menu, src.tags)

proc renderList*(listTitle: string, posts: seq[SourceFile], menu: seq[MenuItem], page, totalPages: int, urlSuffix = ".html"): string =
  var previews: seq[PostPreview]
  for post in posts:
    let url = post.slug & urlSuffix
    previews.add(PostPreview(
      slug: post.slug,
      preview: linkFirstH1(extractPreview(post.content), url),
      url: url,
      date: post.createdAt,
      tags: post.tags
    ))
  listTemplate(listTitle, previews, menu, page, totalPages)
