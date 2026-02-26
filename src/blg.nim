## blg - Blog Generator
##
## One-shot blog generator from markdown files.
## Tags are implemented as subdirectories with symlinks.

import std/[os, times, tables, strutils, sequtils, sets, algorithm, parseopt, envvars, options]
import blg/[renderer, types, dynload, datetime, md]
when defined(linux):
  import blg/daemon

const defaultThemeCss = staticRead("../assets/default-theme.css")

var templateLib: TemplateLib
var ext: string = "html"  # file extension, set from BLG_EXT
var siteConfig: SiteConfig

proc suffix(): string =
  ## Returns ".ext" or "" if ext is empty
  if ext.len > 0: "." & ext else: ""

type
  MenuEntry = object
    kind: string  # "tag", "page", or "text" (unlinked)
    slug: string
    label: string
    indent: int   # indentation level (0 = top, 1 = child, 2 = grandchild)

proc loadMenuList(path: string, tags: seq[string], pageSlugs: HashSet[string]): seq[seq[MenuEntry]] =
  ## Load menu.list file with support for:
  ## - Multiple menus separated by blank lines
  ## - Nested items via indentation (1 space = child of previous)
  ## - Plain text items (neither tag nor page)
  ## Returns seq of menus, each containing entries with indent levels
  var tagSlugs: Table[string, string]  # normalized slug -> original tag name
  for tag in tags:
    tagSlugs[toTagSlug(tag)] = tag

  if not fileExists(path):
    var defaultMenu: seq[MenuEntry]
    defaultMenu.add(MenuEntry(kind: "page", slug: "index", label: "Home", indent: 0))
    var sortedTags = tags
    sortedTags.sort()
    for tag in sortedTags:
      let slug = toTagSlug(tag)
      defaultMenu.add(MenuEntry(kind: "tag", slug: slug, label: toTitleCase(slug), indent: 0))
    result.add(defaultMenu)
    return

  var currentMenu: seq[MenuEntry]
  for line in lines(path):
    # Check for blank line (menu separator)
    if line.strip().len == 0:
      if currentMenu.len > 0:
        result.add(currentMenu)
        currentMenu = @[]
      continue

    # Skip comments
    let trimmed = line.strip()
    if trimmed.startsWith("#"):
      continue

    # Count leading spaces for indentation
    var indent = 0
    for c in line:
      if c == ' ':
        inc indent
      else:
        break

    let normalized = toTagSlug(trimmed)
    if normalized in tagSlugs:
      currentMenu.add(MenuEntry(kind: "tag", slug: normalized, label: trimmed, indent: indent))
    elif normalized in pageSlugs or normalized == "index":
      # "index" is always valid (homepage list)
      let label = if normalized == "index": "Home" else: trimmed
      currentMenu.add(MenuEntry(kind: "page", slug: normalized, label: label, indent: indent))
    else:
      # Plain text - neither tag nor page
      currentMenu.add(MenuEntry(kind: "text", slug: "", label: trimmed, indent: indent))

  # Don't forget the last menu
  if currentMenu.len > 0:
    result.add(currentMenu)

proc buildMenuItems(entries: seq[MenuEntry], activeItem: string, startIdx: var int, parentIndent: int): seq[MenuItem] =
  ## Recursively build MenuItem tree from flat entries with indentation
  let normalizedActive = toTagSlug(activeItem)
  while startIdx < entries.len:
    let entry = entries[startIdx]
    if entry.indent <= parentIndent and startIdx > 0:
      # This entry belongs to a parent level, stop here
      break

    if entry.indent > parentIndent + 1:
      # Skip entries that are too deeply indented (malformed)
      inc startIdx
      continue

    inc startIdx
    var item = MenuItem(
      url: if entry.kind == "text": "" else: entry.slug & suffix(),
      label: entry.label,
      active: entry.kind != "text" and normalizedActive == entry.slug
    )
    # Recursively collect children
    item.children = buildMenuItems(entries, activeItem, startIdx, entry.indent)
    result.add(item)

proc buildMenus(menuEntries: seq[seq[MenuEntry]], activeItem: string): seq[seq[MenuItem]] =
  ## Convert all menus from entries to MenuItem objects with active state
  for entries in menuEntries:
    var idx = 0
    result.add(buildMenuItems(entries, activeItem, idx, -1))

# Template rendering with dynload fallback
proc doRenderPage(src: SourceFile, menus: seq[seq[MenuItem]]): string =
  if templateLib.renderPage != nil:
    templateLib.renderPage(src.title, src.content, src.createdAt, src.modifiedAt, menus).processLinks(siteConfig)
  else:
    renderPage(src, menus, siteConfig)

proc doRenderPost(src: SourceFile, menus: seq[seq[MenuItem]]): string =
  if templateLib.renderPost != nil:
    templateLib.renderPost(src.title, src.content, src.createdAt, src.modifiedAt, menus, src.tags).processLinks(siteConfig)
  else:
    renderPost(src, menus, siteConfig)

proc doRenderList(listTitle: string, posts: seq[SourceFile], menus: seq[seq[MenuItem]], page, totalPages: int): string =
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
    templateLib.renderList(listTitle, previews, menus, page, totalPages).processLinks(siteConfig)
  else:
    renderList(listTitle, posts, menus, page, totalPages, suffix(), siteConfig)

proc discoverSourceFiles(contentDir: string): seq[SourceFile] =
  ## Find all .md files in content directory and gather metadata
  for path in walkFiles(contentDir / "*.md"):
    let info = getFileInfo(path)
    let content = readFile(path)
    let slug = path.splitFile.name
    # Use date from markdown first line if present, else fallback to file mtime
    let extracted = extractIsoDate(content)
    let (createdAt, hasTime) = if extracted.isSome: extracted.get else: (info.lastWriteTime, false)
    result.add(SourceFile(
      path: path,
      slug: slug,
      title: extractMarkdownTitle(content),
      createdAt: createdAt,
      createdAtHasTime: hasTime,
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
  helperLib = templateLib  # Enable helper overrides in renderer

  let menuListPath = contentDir / "menu.list"

  var sources = discoverSourceFiles(contentDir)
  let tags = discoverTags(contentDir)
  let tagNames = toSeq(tags.keys).toHashSet

  # Build set of existing source slugs for menu validation
  var sourceSlugs: HashSet[string]
  for src in sources:
    sourceSlugs.incl(src.slug)

  let menuEntries = loadMenuList(menuListPath, toSeq(tags.keys), sourceSlugs)
  # Extract page slugs from menu entries for checking which sources are pages vs posts
  var menuPageSlugs: HashSet[string]
  for menu in menuEntries:
    for entry in menu:
      if entry.kind == "page":
        menuPageSlugs.incl(entry.slug)

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
      let menus = buildMenus(menuEntries, src.slug)
      if src.slug in menuPageSlugs:
        writeFile(outPath, doRenderPage(src, menus))
        pagesBuilt += 1
      else:
        writeFile(outPath, doRenderPost(src, menus))
        postsBuilt += 1
      echo "  ", outPath

  # Generate paginated index
  let postsChanged = posts.anyIt(it.slug in changed)
  let indexPages = paginate(posts, perPage)
  var listsBuilt = 0
  let indexMenus = buildMenus(menuEntries, "index")
  for p, pagePosts in indexPages:
    let outPath = listPagePath(outputDir, "index", p + 1)
    if force or postsChanged or needsRegen(outPath, menuMtime):
      writeFile(outPath, doRenderList("index", pagePosts, indexMenus, p + 1, indexPages.len))
      echo "  ", outPath
      listsBuilt += 1

  # Generate paginated tag pages (flat: tutorials.html, tutorials-2.html)
  for tagName, taggedFiles in tags:
    let tagSlug = toTagSlug(tagName)
    let tagSet = taggedFiles.toHashSet
    let tagPosts = posts.filterIt(it.slug in tagSet)
    let tagChanged = tagPosts.anyIt(it.slug in changed)
    let tagPages = paginate(tagPosts, perPage)
    let tagMenus = buildMenus(menuEntries, tagSlug)
    for p, pagePosts in tagPages:
      let outPath = listPagePath(outputDir, tagSlug, p + 1)
      if force or tagChanged or needsRegen(outPath, menuMtime):
        writeFile(outPath, doRenderList(toTitleCase(tagSlug), pagePosts, tagMenus, p + 1, tagPages.len))
        echo "  ", outPath
        listsBuilt += 1

  echo "Built: ", pagesBuilt, " pages, ", postsBuilt, " posts, ", listsBuilt, " lists (", changed.len, " sources changed)"

proc initPublicDir(outputDir: string) =
  ## Initialize public directory with default theme if it doesn't exist
  createDir(outputDir)
  let stylePath = outputDir / "style.css"
  if not fileExists(stylePath):
    writeFile(stylePath, defaultThemeCss)
    echo "Created default theme: ", stylePath

proc validateInputDir(inputDir: string) =
  ## Ensure input directory exists and has at least one markdown file
  if not dirExists(inputDir):
    echo "Error: input directory '", inputDir, "' does not exist"
    quit(1)
  var hasMd = false
  for path in walkFiles(inputDir / "*.md"):
    hasMd = true
    break
  if not hasMd:
    echo "Error: no markdown files found in '", inputDir, "'"
    quit(1)

proc validateDirAccess(dir, name: string) =
  ## Check directory is readable/writable, create if needed
  if dirExists(dir):
    # Check readable
    try:
      for _ in walkDir(dir):
        break
    except OSError:
      echo "Error: ", name, " directory '", dir, "' is not readable"
      quit(1)
    # Check writable by testing file creation
    let testFile = dir / ".blg-access-test"
    try:
      writeFile(testFile, "")
      removeFile(testFile)
    except IOError, OSError:
      echo "Error: ", name, " directory '", dir, "' is not writable"
      quit(1)

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

Environment variables:
  BLG_INPUT, BLG_OUTPUT, BLG_CACHE, BLG_PER_PAGE, BLG_EXT, BLG_DATE_FORMAT
  BLG_BASE_URL (prepend to relative URLs), BLG_SITE_TITLE, BLG_SITE_DESCRIPTION
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
  siteConfig = loadSiteConfig()
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

  # Validate input directory
  validateInputDir(inputDir)

  # Initialize public dir with default theme if it doesn't exist
  if not dirExists(outputDir):
    initPublicDir(outputDir)

  # Validate cache and output directories are accessible
  createDir(cacheDir)
  validateDirAccess(cacheDir, "cache")
  validateDirAccess(outputDir, "output")

  when defined(linux):
    if daemonMode:
      buildSite(inputDir, outputDir, cacheDir, perPage, forceMode)
      watchAndRebuild(inputDir, proc() = buildSite(inputDir, outputDir, cacheDir, perPage))
    else:
      buildSite(inputDir, outputDir, cacheDir, perPage, forceMode)
  else:
    buildSite(inputDir, outputDir, cacheDir, perPage, forceMode)
