## blg - Blog Generator
##
## One-shot blog generator from markdown files.
## Tags are implemented as subdirectories with symlinks.

import std/[os, times, tables, strutils, sequtils, sets, algorithm, parseopt, envvars]
import blg/[renderer, types]

proc loadMenuList(path: string): seq[string] =
  ## Load menu.list file - each line is a markdown filename, tag, or 'index'
  if not fileExists(path):
    return @[]
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len > 0 and not trimmed.startsWith("#"):
      result.add(trimmed)

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

proc discoverTags(tagsDir: string): Table[string, seq[string]] =
  ## Discover tags from subdirectories containing symlinks
  if not dirExists(tagsDir):
    return
  for kind, tagPath in walkDir(tagsDir):
    if kind == pcDir:
      let tagName = tagPath.splitPath.tail
      result[tagName] = @[]
      for linkKind, linkPath in walkDir(tagPath):
        if linkKind == pcLinkToFile:
          result[tagName].add(expandSymlink(linkPath).splitFile.name)

proc needsRegen(outPath: string, srcMtime: Time): bool =
  ## Check if output needs regeneration based on source mtime
  if not fileExists(outPath):
    return true
  getFileInfo(outPath).lastWriteTime < srcMtime

proc buildSite*(contentDir, outputDir, cacheDir: string) =
  ## Build the entire site, only regenerating what changed
  let menuListPath = contentDir / "menu.list"
  let tagsDir = contentDir / "tags"

  let menuItems = loadMenuList(menuListPath)
  let menuSet = menuItems.toHashSet
  var sources = discoverSourceFiles(contentDir)
  let tags = discoverTags(tagsDir)

  # Track menu.list mtime for list invalidation
  let menuMtime = if fileExists(menuListPath): getFileInfo(menuListPath).lastWriteTime
                  else: fromUnix(0)

  createDir(outputDir)
  createDir(cacheDir)

  # Render markdown and track what changed
  var changed: HashSet[string]
  for i, src in sources.mpairs:
    let (content, wasChanged) = renderMarkdown(src.path, cacheDir)
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
    let outPath = outputDir / src.title & ".html"
    if src.title in changed or not fileExists(outPath):
      if src.title in menuSet:
        writeFile(outPath, renderPage(src, menuItems))
        pagesBuilt += 1
      else:
        writeFile(outPath, renderPost(src, menuItems))
        postsBuilt += 1
      echo "  ", outPath

  # Generate index if any post changed, menu changed, or output missing
  let indexPath = outputDir / "index.html"
  let postsChanged = posts.anyIt(it.title in changed)
  if postsChanged or needsRegen(indexPath, menuMtime):
    writeFile(indexPath, renderList("index", posts, menuItems))
    echo "  ", indexPath

  # Generate tag pages (only if tagged posts changed or output missing)
  var tagsBuilt = 0
  for tagName, taggedFiles in tags:
    let tagSet = taggedFiles.toHashSet
    let tagPosts = posts.filterIt(it.title in tagSet)
    let tagChanged = tagPosts.anyIt(it.title in changed)
    let tagDir = outputDir / tagName
    let tagIndexPath = tagDir / "index.html"
    if tagChanged or needsRegen(tagIndexPath, menuMtime):
      createDir(tagDir)
      writeFile(tagIndexPath, renderList(tagName, tagPosts, menuItems))
      echo "  ", tagIndexPath
      tagsBuilt += 1

  echo "Built: ", pagesBuilt, " pages, ", postsBuilt, " posts, ", tagsBuilt, " tags (", changed.len, " sources changed)"

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

Usage: blg -i <input-dir> [options]

Options:
  -i, --input <dir>    Input directory (required)
  -o, --output <dir>   Output directory (default: current directory)
  --cache <dir>        Cache directory (default: .blg-cache)
  -e, --env <file>     Env file (default: .env)
  -h, --help           Show this help

Environment variables: BLG_INPUT, BLG_OUTPUT, BLG_CACHE

Precedence: option > env var > .env file > default"""
  quit(0)

when isMainModule:
  var
    inputDir = ""
    outputDir = getCurrentDir()
    cacheDir = ".blg-cache"
    envFile = ".env"
    expectVal = ""

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

  # Second pass: CLI args override env
  expectVal = ""
  for kind, key, val in getopt():
    if expectVal != "":
      case expectVal
      of "o": outputDir = key
      of "i": inputDir = key
      of "cache": cacheDir = key
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
        of "cache": cacheDir = val
        of "e", "env": discard  # already handled
        else: echo "Unknown option: ", key; quit(1)
      else:
        case key
        of "o", "output": expectVal = "o"
        of "i", "input": expectVal = "i"
        of "cache": expectVal = "cache"
        of "e", "env": expectVal = "env"
        of "h", "help": usage()
        else: echo "Unknown option: ", key; quit(1)
    of cmdArgument:
      echo "Unexpected argument: ", key; quit(1)
    of cmdEnd: discard

  if inputDir == "":
    echo "Error: input directory is required (-i <dir> or BLG_INPUT)"
    quit(1)

  buildSite(inputDir, outputDir, cacheDir)
