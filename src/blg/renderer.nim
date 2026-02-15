## Markdown rendering with caching and template application

import std/[os, times, strutils]
import md, types

include "../templates/page.nimf"
include "../templates/post.nimf"
include "../templates/list.nimf"

proc renderMarkdown*(path: string, cacheDir: string): string =
  ## Render markdown to HTML, using cache if source is unmodified
  let cachePath = cacheDir / path.splitFile.name & ".html"
  let srcMtime = getFileInfo(path).lastWriteTime

  if fileExists(cachePath):
    let cacheMtime = getFileInfo(cachePath).lastWriteTime
    if cacheMtime > srcMtime:
      return readFile(cachePath)

  let content = readFile(path)
  result = markdown(content)
  createDir(cacheDir)
  writeFile(cachePath, result)

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
  ## Render a page using the page template
  pageTemplate(src.title, src.content, menuItems, formatDate(src.createdAt), formatDate(src.modifiedAt))

proc renderPost*(src: SourceFile, menuItems: seq[string]): string =
  ## Render a post using the post template
  postTemplate(src.title, src.content, menuItems, formatDate(src.createdAt), formatDate(src.modifiedAt))

proc renderList*(name: string, posts: seq[SourceFile], menuItems: seq[string]): string =
  ## Render a list of posts using the list template (always regenerated)
  var items: seq[tuple[title, preview, url, date: string]]
  for post in posts:
    items.add((
      title: post.title,
      preview: extractPreview(post.content),
      url: post.title & ".html",
      date: formatDate(post.createdAt)
    ))
  listTemplate(name, items, menuItems)
