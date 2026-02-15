## blg - Blog Generator
##
## One-shot blog generator from markdown files.
## Tags are implemented as subdirectories with symlinks.

import std/[os, times, tables, strutils, sequtils, sets, algorithm, parseopt]
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

proc buildSite*(contentDir, outputDir, cacheDir: string) =
  ## Build the entire site
  let menuListPath = contentDir / "menu.list"
  let tagsDir = contentDir / "tags"

  let menuItems = loadMenuList(menuListPath)
  let menuSet = menuItems.toHashSet
  var sources = discoverSourceFiles(contentDir)
  let tags = discoverTags(tagsDir)

  createDir(outputDir)
  createDir(cacheDir)

  # Render content and cache it
  for i, src in sources.mpairs:
    src.content = renderMarkdown(src.path, cacheDir)

  # Determine which files are explicit pages vs posts
  var posts: seq[SourceFile]

  for src in sources:
    if src.title notin menuSet:
      posts.add(src)

  # Generate individual HTML files
  for src in sources:
    let outPath = outputDir / src.title & ".html"
    if src.title in menuSet:
      writeFile(outPath, renderPage(src, menuItems))
    else:
      writeFile(outPath, renderPost(src, menuItems))
    echo "  ", outPath

  # Generate index (all posts not in menu)
  let indexPath = outputDir / "index.html"
  writeFile(indexPath, renderList("index", posts, menuItems))
  echo "  ", indexPath

  # Generate tag pages
  for tagName, taggedFiles in tags:
    let tagPosts = posts.filterIt(it.title in taggedFiles.toHashSet)
    let tagDir = outputDir / tagName
    createDir(tagDir)
    let tagIndexPath = tagDir / "index.html"
    writeFile(tagIndexPath, renderList(tagName, tagPosts, menuItems))
    echo "  ", tagIndexPath

  echo "Built: ", sources.len, " files, ", tags.len, " tags"

proc loadConfig(path: string): Table[string, string] =
  ## Load config file (key=value format, same names as long params)
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
      result[key] = val

proc usage() =
  echo """blg - Blog Generator

Usage: blg -i <input-dir> [options]

Options:
  -i, --input <dir>    Input directory (required)
  -o, --output <dir>   Output directory (default: current directory)
  -c, --config <file>  Config file (default: blg.conf)
  --cache <dir>        Cache directory (default: .blg-cache)
  -h, --help           Show this help

Config file format (same keys as long options):
  input=path/to/input
  output=path/to/output
  cache=.blg-cache"""
  quit(0)

when isMainModule:
  var
    inputDir = ""
    outputDir = getCurrentDir()
    cacheDir = ".blg-cache"
    configFile = "blg.conf"
    expectVal = ""

  # First pass: find config file option
  for kind, key, val in getopt():
    if expectVal == "config":
      configFile = key
      expectVal = ""
      continue
    if kind in {cmdShortOption, cmdLongOption}:
      if val != "" and key in ["c", "config"]:
        configFile = val
      elif val == "" and key in ["c", "config"]:
        expectVal = "config"

  # Load config file
  let conf = loadConfig(configFile)
  if "input" in conf: inputDir = conf["input"]
  if "output" in conf: outputDir = conf["output"]
  if "cache" in conf: cacheDir = conf["cache"]

  # Second pass: CLI args override config
  expectVal = ""
  for kind, key, val in getopt():
    if expectVal != "":
      case expectVal
      of "o": outputDir = key
      of "i": inputDir = key
      of "cache": cacheDir = key
      of "config": discard  # already handled
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
        of "c", "config": discard  # already handled
        else: echo "Unknown option: ", key; quit(1)
      else:
        case key
        of "o", "output": expectVal = "o"
        of "i", "input": expectVal = "i"
        of "cache": expectVal = "cache"
        of "c", "config": expectVal = "config"
        of "h", "help": usage()
        else: echo "Unknown option: ", key; quit(1)
    of cmdArgument:
      echo "Unexpected argument: ", key; quit(1)
    of cmdEnd: discard

  if inputDir == "":
    echo "Error: input directory is required (-i <dir> or input= in config)"
    quit(1)

  buildSite(inputDir, outputDir, cacheDir)
