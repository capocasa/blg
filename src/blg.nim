## blg - Blog Generator
##
## One-shot blog generator from markdown files.
## Tags are implemented as subdirectories with symlinks.

import std/[os, times, tables, strutils, sequtils, sets, algorithm, parseopt, envvars, dynlib]
import blg/[renderer, types, dynload]
when defined(linux):
  import blg/daemon

var templateLib: TemplateLib
var ext: string = "html"  # file extension, set from BLG_EXT

proc suffix(): string =
  ## Returns ".ext" or "" if ext is empty
  if ext.len > 0: "." & ext else: ""

proc loadMenuList(path: string, tags: seq[string]): seq[string] =
  ## Load menu.list file - each line is a markdown filename, tag, or 'index'
  ## If file doesn't exist, default to index + tags alphabetically
  if not fileExists(path):
    result.add("index")
    var sortedTags = tags
    sortedTags.sort()
    for tag in sortedTags:
      result.add("tag:" & tag)
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len > 0 and not trimmed.startsWith("#"):
      result.add(trimmed)

proc buildMenu(menuItems: seq[string], activeItem: string): seq[MenuItem] =
  ## Convert menu.list entries to MenuItem objects with active state
  for item in menuItems:
    if item == "index":
      result.add(MenuItem(url: "index" & suffix(), label: "Home", active: activeItem == "index"))
    elif item.startsWith("tag:"):
      let tag = item[4..^1]
      result.add(MenuItem(url: tag & suffix(), label: tag, active: activeItem == tag))
    else:
      result.add(MenuItem(url: item & suffix(), label: item, active: activeItem == item))

# Template rendering with dynload fallback
proc doRenderPage(src: SourceFile, menu: seq[MenuItem]): string =
  if templateLib.renderPage != nil:
    templateLib.renderPage(src.title, src.content, src.createdAt, src.modifiedAt, menu)
  else:
    renderPage(src, menu)

proc doRenderPost(src: SourceFile, menu: seq[MenuItem]): string =
  if templateLib.renderPost != nil:
    templateLib.renderPost(src.title, src.content, src.createdAt, src.modifiedAt, menu)
  else:
    renderPost(src, menu)

proc doRenderList(title: string, posts: seq[SourceFile], menu: seq[MenuItem], page, totalPages: int): string =
  if templateLib.renderList != nil:
    var previews: seq[PostPreview]
    for post in posts:
      previews.add(PostPreview(
        title: post.title,
        preview: extractPreview(post.content),
        url: post.title & suffix(),
        date: post.createdAt
      ))
    templateLib.renderList(title, previews, menu, page, totalPages)
  else:
    renderList(title, posts, menu, page, totalPages, suffix())

proc discoverSourceFiles(contentDir: string): seq[SourceFile] =
  ## Find all .md files in content directory and gather metadata
  for path in walkFiles(contentDir / "*.md"):
    let info = getFileInfo(path)
    result.add(SourceFile(
      path: path,
      title: path.splitFile.name,
      createdAt: info.creationTime,
      modifiedAt: info.lastWriteTime,
    ))
  result.sort(proc(a, b: SourceFile): int = cmp(b.createdAt, a.createdAt))

proc discoverTags(contentDir: string): Table[string, seq[string]] =
  ## Discover tags from subdirectories containing symlinks
  ## Directories directly within contentDir represent tags
  for kind, tagPath in walkDir(contentDir):
    if kind == pcDir:
      let tagName = tagPath.splitPath.tail
      var tagged: seq[string]
      for linkKind, linkPath in walkDir(tagPath):
        if linkKind == pcLinkToFile:
          tagged.add(expandSymlink(linkPath).splitFile.name)
      if tagged.len > 0:
        result[tagName] = tagged

proc needsRegen(outPath: string, srcMtime: Time): bool =
  ## Check if output needs regeneration based on source mtime
  if not fileExists(outPath):
    return true
  getFileInfo(outPath).lastWriteTime < srcMtime

proc paginate(items: seq[SourceFile], perPage: int): seq[seq[SourceFile]] =
  ## Split items into pages
  if items.len == 0:
    result.add(@[])
    return
  var i = 0
  while i < items.len:
    result.add(items[i ..< min(i + perPage, items.len)])
    i += perPage

proc listPagePath(outputDir, name: string, page: int): string =
  ## Generate path for a list page: name.html, name-2.html, etc.
  if page == 1: outputDir / name & suffix()
  else: outputDir / name & "-" & $page & suffix()

proc buildSite*(contentDir, outputDir, cacheDir: string, perPage: int, force = false) =
  ## Build the entire site, only regenerating what changed
  ## If force=true, regenerate everything ignoring cache

  # Try to load custom templates
  let templatePath = cacheDir / DynlibFormat % "template"
  templateLib = loadTemplateLib(templatePath)

  let menuListPath = contentDir / "menu.list"

  var sources = discoverSourceFiles(contentDir)
  let tags = discoverTags(contentDir)
  let tagNames = toSeq(tags.keys).toHashSet
  let menuItems = loadMenuList(menuListPath, toSeq(tags.keys))
  let menuSet = menuItems.toHashSet

  # Validate: pages shouldn't be named like tags
  for src in sources:
    if src.title in tagNames:
      echo "Error: page '", src.title, "' has same name as tag directory"
      quit(1)

  # Track menu.list mtime for list invalidation
  let menuMtime = if fileExists(menuListPath): getFileInfo(menuListPath).lastWriteTime
                  else: fromUnix(0)

  createDir(outputDir)
  createDir(cacheDir)

  # Render markdown and track what changed
  var changed: HashSet[string]
  for i, src in sources.mpairs:
    let (content, wasChanged) = renderMarkdown(src.path, cacheDir, force)
    src.content = content
    if wasChanged:
      changed.incl(src.title)

  # Determine which files are explicit pages vs posts
  var posts: seq[SourceFile]
  for src in sources:
    if src.title notin menuSet:
      posts.add(src)

  # Generate individual HTML files (only if source changed or output missing)
  var pagesBuilt, postsBuilt = 0
  for src in sources:
    let outPath = outputDir / src.title & suffix()
    if force or src.title in changed or not fileExists(outPath):
      let menu = buildMenu(menuItems, src.title)
      if src.title in menuSet:
        writeFile(outPath, doRenderPage(src, menu))
        pagesBuilt += 1
      else:
        writeFile(outPath, doRenderPost(src, menu))
        postsBuilt += 1
      echo "  ", outPath

  # Generate paginated index
  let postsChanged = posts.anyIt(it.title in changed)
  let indexPages = paginate(posts, perPage)
  var listsBuilt = 0
  let indexMenu = buildMenu(menuItems, "index")
  for p, pagePosts in indexPages:
    let outPath = listPagePath(outputDir, "index", p + 1)
    if force or postsChanged or needsRegen(outPath, menuMtime):
      writeFile(outPath, doRenderList("index", pagePosts, indexMenu, p + 1, indexPages.len))
      echo "  ", outPath
      listsBuilt += 1

  # Generate paginated tag pages (flat: tutorials.html, tutorials-2.html)
  for tagName, taggedFiles in tags:
    let tagSet = taggedFiles.toHashSet
    let tagPosts = posts.filterIt(it.title in tagSet)
    let tagChanged = tagPosts.anyIt(it.title in changed)
    let tagPages = paginate(tagPosts, perPage)
    let tagMenu = buildMenu(menuItems, tagName)
    for p, pagePosts in tagPages:
      let outPath = listPagePath(outputDir, tagName, p + 1)
      if force or tagChanged or needsRegen(outPath, menuMtime):
        writeFile(outPath, doRenderList(tagName, pagePosts, tagMenu, p + 1, tagPages.len))
        echo "  ", outPath
        listsBuilt += 1

  echo "Built: ", pagesBuilt, " pages, ", postsBuilt, " posts, ", listsBuilt, " lists (", changed.len, " sources changed)"

proc loadEnvFile(path: string) =
  ## Load .env file into environment variables
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let eq = trimmed.find('=')
    if eq > 0:
      let key = trimmed[0..<eq].strip()
      let val = trimmed[eq+1..^1].strip()
      if not existsEnv(key):  # don't override existing env
        putEnv(key, val)

proc usage() =
  echo """blg - Blog Generator

Usage: blg [options]

Options:
  -i, --input <dir>    Input directory (default: md)
  -o, --output <dir>   Output directory (default: public)
  -c, --cache <dir>    Cache directory (default: cache)
  --per-page <n>       Items per page (default: 20)
  -f, --force          Force regenerate all (ignore cache)"""
  when defined(linux):
    echo "  -d, --daemon         Watch for changes and rebuild (5s debounce)"
  echo """  -e, --env <file>     Env file (default: .env)
  -h, --help           Show this help

Environment variables: BLG_INPUT, BLG_OUTPUT, BLG_CACHE, BLG_PER_PAGE, BLG_EXT

Precedence: option > env var > .env file > default"""
  quit(0)

when isMainModule:
  var
    inputDir = "md"
    outputDir = "public"
    cacheDir = "cache"
    perPage = 20
    envFile = ".env"
    expectVal = ""
    forceMode = false
  when defined(linux):
    var daemonMode = false

  # First pass: find env file option
  for kind, key, val in getopt():
    if expectVal == "env":
      envFile = key
      expectVal = ""
      continue
    if kind in {cmdShortOption, cmdLongOption}:
      if val != "" and key in ["e", "env"]:
        envFile = val
      elif val == "" and key in ["e", "env"]:
        expectVal = "env"

  # Load .env file, then read env vars
  loadEnvFile(envFile)
  if existsEnv("BLG_INPUT"): inputDir = getEnv("BLG_INPUT")
  if existsEnv("BLG_OUTPUT"): outputDir = getEnv("BLG_OUTPUT")
  if existsEnv("BLG_CACHE"): cacheDir = getEnv("BLG_CACHE")
  if existsEnv("BLG_PER_PAGE"): perPage = parseInt(getEnv("BLG_PER_PAGE"))
  if existsEnv("BLG_EXT"): ext = getEnv("BLG_EXT")

  # Second pass: CLI args override env
  expectVal = ""
  for kind, key, val in getopt():
    if expectVal != "":
      case expectVal
      of "o": outputDir = key
      of "i": inputDir = key
      of "c": cacheDir = key
      of "per-page": perPage = parseInt(key)
      of "env": discard  # already handled
      else: discard
      expectVal = ""
      continue

    case kind
    of cmdShortOption, cmdLongOption:
      if val != "":
        case key
        of "o", "output": outputDir = val
        of "i", "input": inputDir = val
        of "c", "cache": cacheDir = val
        of "per-page": perPage = parseInt(val)
        of "e", "env": discard  # already handled
        else: echo "Unknown option: ", key; quit(1)
      else:
        when defined(linux):
          case key
          of "o", "output": expectVal = "o"
          of "i", "input": expectVal = "i"
          of "c", "cache": expectVal = "c"
          of "per-page": expectVal = "per-page"
          of "e", "env": expectVal = "env"
          of "h", "help": usage()
          of "f", "force": forceMode = true
          of "d", "daemon": daemonMode = true
          else: echo "Unknown option: ", key; quit(1)
        else:
          case key
          of "o", "output": expectVal = "o"
          of "i", "input": expectVal = "i"
          of "c", "cache": expectVal = "c"
          of "per-page": expectVal = "per-page"
          of "e", "env": expectVal = "env"
          of "h", "help": usage()
          of "f", "force": forceMode = true
          else: echo "Unknown option: ", key; quit(1)
    of cmdArgument:
      echo "Unexpected argument: ", key; quit(1)
    of cmdEnd: discard

  when defined(linux):
    if daemonMode:
      buildSite(inputDir, outputDir, cacheDir, perPage, forceMode)
      watchAndRebuild(inputDir, proc() = buildSite(inputDir, outputDir, cacheDir, perPage))
    else:
      buildSite(inputDir, outputDir, cacheDir, perPage, forceMode)
  else:
    buildSite(inputDir, outputDir, cacheDir, perPage, forceMode)
