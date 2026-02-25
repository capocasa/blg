## blg - Blog Generator
##
## One-shot blog generator from markdown files.
## Tags are implemented as subdirectories with symlinks.

import std/[os, times, tables, strutils, sequtils, sets, algorithm, parseopt, envvars, dynlib, options]
import blg/[renderer, types, dynload, datetime, md]
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
  ## Returns entries in format: "tag:slug:label" or "page:slug:label"
  ## All slugs are normalized to lowercase-hyphenated
  var tagSlugs: Table[string, string]  # normalized slug -> original tag name
  for tag in tags:
    tagSlugs[toTagSlug(tag)] = tag

  if not fileExists(path):
    result.add("page:index:Home")
    var sortedTags = tags
    sortedTags.sort()
    for tag in sortedTags:
      let slug = toTagSlug(tag)
      let label = toTitleCase(slug)
      result.add("tag:" & slug & ":" & label)
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len > 0 and not trimmed.startsWith("#"):
      let normalized = toTagSlug(trimmed)
      if normalized in tagSlugs:
        # It's a tag reference - use normalized slug for URL, original text for display
        result.add("tag:" & normalized & ":" & trimmed)
      else:
        # It's a page reference - normalize slug, keep original for display
        # Special case: "index" displays as "Home" by default
        let label = if normalized == "index": "Home" else: trimmed
        result.add("page:" & normalized & ":" & label)

proc buildMenu(menuItems: seq[string], activeItem: string, pageTitles: Table[string, string]): seq[MenuItem] =
  ## Convert menu.list entries to MenuItem objects with active state
  ## pageTitles maps slug -> display title for pages
  ## Format: "tag:slug:label" or "page:slug:label"
  let normalizedActive = toTagSlug(activeItem)
  for item in menuItems:
    if item.startsWith("tag:"):
      let rest = item[4..^1]
      let colonPos = rest.find(':')
      let (slug, label) = if colonPos >= 0:
        (rest[0..<colonPos], rest[colonPos+1..^1])
      else:
        (rest, rest)  # fallback
      result.add(MenuItem(url: slug & suffix(), label: label, active: normalizedActive == slug))
    elif item.startsWith("page:"):
      let rest = item[5..^1]
      let colonPos = rest.find(':')
      let (slug, label) = if colonPos >= 0:
        (rest[0..<colonPos], rest[colonPos+1..^1])
      else:
        (rest, rest)  # fallback
      result.add(MenuItem(url: slug & suffix(), label: label, active: normalizedActive == slug))
    else:
      # Legacy fallback for raw entries
      let label = pageTitles.getOrDefault(item, item)
      result.add(MenuItem(url: item & suffix(), label: label, active: activeItem == item))

# Template rendering with dynload fallback
proc doRenderPage(src: SourceFile, menu: seq[MenuItem]): string =
  if templateLib.renderPage != nil:
    templateLib.renderPage(src.slug, src.content, src.createdAt, src.modifiedAt, menu)
  else:
    renderPage(src, menu)

proc doRenderPost(src: SourceFile, menu: seq[MenuItem]): string =
  if templateLib.renderPost != nil:
    templateLib.renderPost(src.slug, src.content, src.createdAt, src.modifiedAt, menu, src.tags)
  else:
    renderPost(src, menu)

proc doRenderList(listTitle: string, posts: seq[SourceFile], menu: seq[MenuItem], page, totalPages: int): string =
  if templateLib.renderList != nil:
    var previews: seq[PostPreview]
    for post in posts:
      let url = post.slug & suffix()
      previews.add(PostPreview(
        slug: post.slug,
        preview: linkFirstH1(extractPreview(post.content), url),
        url: url,
        date: post.createdAt,
        tags: post.tags
      ))
    templateLib.renderList(listTitle, previews, menu, page, totalPages)
  else:
    renderList(listTitle, posts, menu, page, totalPages, suffix())

proc discoverSourceFiles(contentDir: string): seq[SourceFile] =
  ## Find all .md files in content directory and gather metadata
  for path in walkFiles(contentDir / "*.md"):
    let info = getFileInfo(path)
    let content = readFile(path)
    let slug = path.splitFile.name
    # Use date from markdown first line if present, else fallback to file mtime
    let createdAt = extractIsoDate(content).get(info.lastWriteTime)
    result.add(SourceFile(
      path: path,
      slug: slug,
      title: extractMarkdownTitle(content),
      createdAt: createdAt,
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
  # Extract page slugs from menu items for checking which sources are pages vs posts
  var menuPageSlugs: HashSet[string]
  for item in menuItems:
    if item.startsWith("page:"):
      let rest = item[5..^1]
      let colonPos = rest.find(':')
      if colonPos >= 0:
        menuPageSlugs.incl(rest[0..<colonPos])
      else:
        menuPageSlugs.incl(rest)

  # Build page titles table for menu display
  var pageTitles: Table[string, string]
  for src in sources:
    if src.title.len > 0:
      pageTitles[src.slug] = src.title

  # Populate tags on each source file
  for i in 0..<sources.len:
    for tagName, taggedFiles in tags:
      if sources[i].slug in taggedFiles:
        let slug = toTagSlug(tagName)
        sources[i].tags.add(TagInfo(slug: slug, label: toTitleCase(slug)))

  # Validate: pages shouldn't be named like tags
  for src in sources:
    if src.slug in tagNames:
      echo "Error: page '", src.slug, "' has same name as tag directory"
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
      changed.incl(src.slug)

  # Determine which files are explicit pages vs posts
  var posts: seq[SourceFile]
  for src in sources:
    if src.slug notin menuPageSlugs:
      posts.add(src)

  # Generate individual HTML files (only if source changed or output missing)
  var pagesBuilt, postsBuilt = 0
  for src in sources:
    let outPath = outputDir / src.slug & suffix()
    if force or src.slug in changed or not fileExists(outPath):
      let menu = buildMenu(menuItems, src.slug, pageTitles)
      if src.slug in menuPageSlugs:
        writeFile(outPath, doRenderPage(src, menu))
        pagesBuilt += 1
      else:
        writeFile(outPath, doRenderPost(src, menu))
        postsBuilt += 1
      echo "  ", outPath

  # Generate paginated index
  let postsChanged = posts.anyIt(it.slug in changed)
  let indexPages = paginate(posts, perPage)
  var listsBuilt = 0
  let indexMenu = buildMenu(menuItems, "index", pageTitles)
  for p, pagePosts in indexPages:
    let outPath = listPagePath(outputDir, "index", p + 1)
    if force or postsChanged or needsRegen(outPath, menuMtime):
      writeFile(outPath, doRenderList("index", pagePosts, indexMenu, p + 1, indexPages.len))
      echo "  ", outPath
      listsBuilt += 1

  # Generate paginated tag pages (flat: tutorials.html, tutorials-2.html)
  for tagName, taggedFiles in tags:
    let tagSlug = toTagSlug(tagName)
    let tagSet = taggedFiles.toHashSet
    let tagPosts = posts.filterIt(it.slug in tagSet)
    let tagChanged = tagPosts.anyIt(it.slug in changed)
    let tagPages = paginate(tagPosts, perPage)
    let tagMenu = buildMenu(menuItems, tagSlug, pageTitles)
    for p, pagePosts in tagPages:
      let outPath = listPagePath(outputDir, tagSlug, p + 1)
      if force or tagChanged or needsRegen(outPath, menuMtime):
        writeFile(outPath, doRenderList(toTitleCase(tagSlug), pagePosts, tagMenu, p + 1, tagPages.len))
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

Environment variables: BLG_INPUT, BLG_OUTPUT, BLG_CACHE, BLG_PER_PAGE, BLG_EXT, BLG_DATE_FORMAT
  Date presets: iso, us-long, us-short, eu-long, eu-medium, eu-short, uk (or custom format)

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
  initDateFormat()  # Must be after loadEnvFile
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
