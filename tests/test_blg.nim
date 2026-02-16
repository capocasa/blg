import std/[unittest, os, strutils, times, envvars, osproc, strtabs]
import blg

const TestDir = "/tmp/blg-test"

proc cleanup() =
  if dirExists(TestDir):
    removeDir(TestDir)

proc setupTestDir(): string =
  cleanup()
  createDir(TestDir)
  TestDir

proc createPost(dir, name, content: string, age: int = 0) =
  ## Create a markdown file. Age in seconds for ordering.
  let path = dir / name & ".md"
  writeFile(path, content)
  # Set mtime to control ordering (older = higher age value)
  let t = getTime() - initDuration(seconds = age)
  setLastModificationTime(path, t)

proc createTag(pagesDir, tagName: string, posts: seq[string]) =
  ## Create a tag directory with symlinks to posts
  let tagDir = pagesDir / tagName
  createDir(tagDir)
  for post in posts:
    createSymlink("../" & post & ".md", tagDir / post & ".md")

proc readOutput(path: string): string =
  if fileExists(path): readFile(path) else: ""

proc countLinks(html, pattern: string): int =
  ## Count occurrences of a link pattern in HTML
  var pos = 0
  while true:
    pos = html.find(pattern, pos)
    if pos < 0: break
    result += 1
    pos += 1

proc hasLink(html, href: string): bool =
  html.contains("href=\"" & href & "\"")

suite "Pagination":
  setup:
    let dir = setupTestDir()
    let pages = dir / "pages"
    let output = dir / "public"
    let cache = dir / "html"
    createDir(pages)

  teardown:
    cleanup()

  test "2 posts per page creates multiple pages":
    # Create 5 posts (should create 3 pages with perPage=2)
    createPost(pages, "post1", "# Post 1", age = 50)
    createPost(pages, "post2", "# Post 2", age = 40)
    createPost(pages, "post3", "# Post 3", age = 30)
    createPost(pages, "post4", "# Post 4", age = 20)
    createPost(pages, "post5", "# Post 5", age = 10)

    buildSite(pages, output, cache, perPage = 2)

    check fileExists(output / "index.html")
    check fileExists(output / "index-2.html")
    check fileExists(output / "index-3.html")
    check not fileExists(output / "index-4.html")

    # First page has 2 posts, links to page 2
    let page1 = readOutput(output / "index.html")
    check page1.hasLink("index-2.html")
    check not page1.contains("Previous")

    # Middle page has prev and next
    let page2 = readOutput(output / "index-2.html")
    check page2.hasLink("index.html")  # prev
    check page2.hasLink("index-3.html")  # next

    # Last page has prev only
    let page3 = readOutput(output / "index-3.html")
    check page3.hasLink("index-2.html")
    check not page3.contains("Next")

  test "3 posts per page with tag pagination":
    # Create 7 posts, 5 tagged
    createPost(pages, "p1", "# P1", age = 70)
    createPost(pages, "p2", "# P2", age = 60)
    createPost(pages, "p3", "# P3", age = 50)
    createPost(pages, "p4", "# P4", age = 40)
    createPost(pages, "p5", "# P5", age = 30)
    createPost(pages, "p6", "# P6", age = 20)
    createPost(pages, "p7", "# P7", age = 10)
    createTag(pages, "mytag", @["p1", "p2", "p3", "p4", "p5"])

    buildSite(pages, output, cache, perPage = 3)

    # Index: 7 posts = 3 pages
    check fileExists(output / "index.html")
    check fileExists(output / "index-2.html")
    check fileExists(output / "index-3.html")

    # Tag: 5 posts = 2 pages
    check fileExists(output / "mytag.html")
    check fileExists(output / "mytag-2.html")
    check not fileExists(output / "mytag-3.html")

    # Tag pagination links use tag name
    let tagPage1 = readOutput(output / "mytag.html")
    check tagPage1.hasLink("mytag-2.html")

suite "Index filtering":
  setup:
    let dir = setupTestDir()
    let pages = dir / "pages"
    let output = dir / "public"
    let cache = dir / "html"
    createDir(pages)

  teardown:
    cleanup()

  test "menu items excluded from index list":
    createPost(pages, "about", "# About page")
    createPost(pages, "contact", "# Contact page")
    createPost(pages, "post1", "# Blog post 1")
    createPost(pages, "post2", "# Blog post 2")

    # menu.list includes about and contact as pages
    writeFile(pages / "menu.list", "index\nabout\ncontact")

    buildSite(pages, output, cache, perPage = 20)

    let index = readOutput(output / "index.html")
    # Index should list post1 and post2, not about/contact
    check index.contains("post1")
    check index.contains("post2")
    # about and contact appear in nav, not in post list
    check index.countLinks("about.html") == 1  # nav only
    check index.countLinks("contact.html") == 1  # nav only

  test "all posts shown when no menu.list pages":
    createPost(pages, "post1", "# Post 1")
    createPost(pages, "post2", "# Post 2")
    createPost(pages, "post3", "# Post 3")
    # No menu.list, no tags - default menu is just "index"

    buildSite(pages, output, cache, perPage = 20)

    let index = readOutput(output / "index.html")
    check index.contains("post1")
    check index.contains("post2")
    check index.contains("post3")

suite "Tag filtering":
  setup:
    let dir = setupTestDir()
    let pages = dir / "pages"
    let output = dir / "public"
    let cache = dir / "html"
    createDir(pages)

  teardown:
    cleanup()

  test "tag page shows only tagged posts":
    createPost(pages, "tagged1", "# Tagged 1")
    createPost(pages, "tagged2", "# Tagged 2")
    createPost(pages, "untagged", "# Untagged")
    createTag(pages, "nim", @["tagged1", "tagged2"])

    buildSite(pages, output, cache, perPage = 20)

    let tagPage = readOutput(output / "nim.html")
    check tagPage.contains("tagged1")
    check tagPage.contains("tagged2")
    check not tagPage.contains("untagged")

    # Index shows all posts
    let index = readOutput(output / "index.html")
    check index.contains("tagged1")
    check index.contains("tagged2")
    check index.contains("untagged")

  test "multiple tags filter independently":
    createPost(pages, "nim-post", "# Nim post")
    createPost(pages, "web-post", "# Web post")
    createPost(pages, "both-post", "# Both tags")
    createPost(pages, "no-tag", "# No tag")
    createTag(pages, "nim", @["nim-post", "both-post"])
    createTag(pages, "web", @["web-post", "both-post"])

    buildSite(pages, output, cache, perPage = 20)

    let nimPage = readOutput(output / "nim.html")
    check nimPage.contains("nim-post")
    check nimPage.contains("both-post")
    check not nimPage.contains("web-post")
    check not nimPage.contains("no-tag")

    let webPage = readOutput(output / "web.html")
    check webPage.contains("web-post")
    check webPage.contains("both-post")
    check not webPage.contains("nim-post")
    check not webPage.contains("no-tag")

suite "menu.list behavior":
  setup:
    let dir = setupTestDir()
    let pages = dir / "pages"
    let output = dir / "public"
    let cache = dir / "html"
    createDir(pages)

  teardown:
    cleanup()

  test "menu.list order is respected":
    createPost(pages, "about", "# About")
    createPost(pages, "post1", "# Post")
    createTag(pages, "zzz", @["post1"])
    createTag(pages, "aaa", @["post1"])

    # Custom order: index, zzz tag, about page, aaa tag
    writeFile(pages / "menu.list", "index\ntag:zzz\nabout\ntag:aaa")

    buildSite(pages, output, cache, perPage = 20)

    let index = readOutput(output / "index.html")
    let zzzPos = index.find("zzz.html")
    let aboutPos = index.find("about.html")
    let aaaPos = index.find("aaa.html")

    # zzz before about before aaa
    check zzzPos < aboutPos
    check aboutPos < aaaPos

  test "default menu is index + tags alphabetically":
    createPost(pages, "post1", "# Post")
    createTag(pages, "zebra", @["post1"])
    createTag(pages, "alpha", @["post1"])
    createTag(pages, "middle", @["post1"])
    # No menu.list

    buildSite(pages, output, cache, perPage = 20)

    let index = readOutput(output / "index.html")

    # Should have: Home (index), alpha, middle, zebra
    let homePos = index.find(">Home<")
    let alphaPos = index.find("alpha.html")
    let middlePos = index.find("middle.html")
    let zebraPos = index.find("zebra.html")

    check homePos > 0
    check alphaPos > 0
    check middlePos > 0
    check zebraPos > 0

    # Alphabetical order after index
    check homePos < alphaPos
    check alphaPos < middlePos
    check middlePos < zebraPos

  test "default menu has no pages, only index and tags":
    createPost(pages, "about", "# About")
    createPost(pages, "contact", "# Contact")
    createPost(pages, "post1", "# Post")
    createTag(pages, "news", @["post1"])
    # No menu.list

    buildSite(pages, output, cache, perPage = 20)

    let index = readOutput(output / "index.html")
    let nav = index[index.find("<nav>") .. index.find("</nav>")]

    # Nav should have index and news tag only
    check nav.contains("index.html")
    check nav.contains("news.html")
    # about and contact are posts, not in nav
    check not nav.contains("about.html")
    check not nav.contains("contact.html")

suite "Configuration cascading":
  setup:
    let dir = setupTestDir()
    createDir(dir / "pages")
    createDir(dir / "custom-pages")
    createPost(dir / "pages", "test", "# Test")
    createPost(dir / "custom-pages", "custom", "# Custom")
    # Clear any existing env vars
    delEnv("BLG_INPUT")
    delEnv("BLG_OUTPUT")
    delEnv("BLG_CACHE")
    delEnv("BLG_PER_PAGE")

  teardown:
    delEnv("BLG_INPUT")
    delEnv("BLG_OUTPUT")
    delEnv("BLG_CACHE")
    delEnv("BLG_PER_PAGE")
    cleanup()

  test "env var overrides .env file":
    # Create .env with one set of values
    writeFile(TestDir / ".env", """
BLG_INPUT=pages
BLG_OUTPUT=from-dotenv
BLG_CACHE=cache-dotenv
""")
    createDir(TestDir / "from-dotenv")
    createDir(TestDir / "from-env")

    # Run blg with env var override
    let blgPath = getCurrentDir() / "blg"
    let (_, exitCode) = execCmdEx(blgPath, workingDir = TestDir,
      env = newStringTable({"BLG_OUTPUT": "from-env"}))
    check exitCode == 0
    # Should use env var output dir, not .env
    check dirExists(TestDir / "from-env")
    check fileExists(TestDir / "from-env" / "index.html")

  test "CLI param overrides env var":
    createDir(TestDir / "from-env")
    createDir(TestDir / "from-cli")

    let blgPath = getCurrentDir() / "blg"
    let (_, exitCode) = execCmdEx(blgPath & " -i pages -o from-cli",
      workingDir = TestDir,
      env = newStringTable({"BLG_OUTPUT": "from-env"}))
    check exitCode == 0
    # Should use CLI output dir
    check fileExists(TestDir / "from-cli" / "index.html")

suite "Page-tag collision":
  setup:
    let dir = setupTestDir()
    let pages = dir / "pages"
    createDir(pages)

  teardown:
    cleanup()

  test "error when page name matches tag name":
    createPost(pages, "tutorials", "# Tutorials page")
    createTag(pages, "tutorials", @["tutorials"])  # Same name as page

    # Run via subprocess since quit() can't be caught
    let blgPath = getCurrentDir() / "blg"
    let (output, exitCode) = execCmdEx(blgPath & " -i pages -o public --cache html",
      workingDir = dir)
    check exitCode != 0
    check output.contains("same name as tag")

suite "Cache busting":
  setup:
    let dir = setupTestDir()
    let pages = dir / "pages"
    let output = dir / "public"
    let cache = dir / "html"
    createDir(pages)

  teardown:
    cleanup()

  test "modified source invalidates cache":
    createPost(pages, "post1", "# Original content")
    buildSite(pages, output, cache, perPage = 20)

    let cacheFile = cache / "post1.html"
    let outputFile = output / "post1.html"
    check fileExists(cacheFile)
    check readOutput(cacheFile).contains("Original content")

    # Wait a moment and modify the source
    sleep(100)
    writeFile(pages / "post1.md", "# Updated content")
    # Touch to ensure mtime changes
    setLastModificationTime(pages / "post1.md", getTime())

    buildSite(pages, output, cache, perPage = 20)

    # Cache and output should have new content
    check readOutput(cacheFile).contains("Updated content")
    check readOutput(outputFile).contains("Updated content")

  test "unmodified source uses cache":
    createPost(pages, "post1", "# Content")
    buildSite(pages, output, cache, perPage = 20)

    let cacheFile = cache / "post1.html"
    let cacheMtime = getFileInfo(cacheFile).lastWriteTime

    # Wait and rebuild without changes
    sleep(100)
    buildSite(pages, output, cache, perPage = 20)

    # Cache file should not be modified
    check getFileInfo(cacheFile).lastWriteTime == cacheMtime

  test "new post triggers list regeneration":
    createPost(pages, "post1", "# Post 1", age = 20)
    buildSite(pages, output, cache, perPage = 20)

    let indexMtime = getFileInfo(output / "index.html").lastWriteTime
    let index1 = readOutput(output / "index.html")
    check index1.contains("post1")
    check not index1.contains("post2")

    # Add new post
    sleep(100)
    createPost(pages, "post2", "# Post 2", age = 10)
    buildSite(pages, output, cache, perPage = 20)

    # Index should be regenerated with new post
    check getFileInfo(output / "index.html").lastWriteTime > indexMtime
    let index2 = readOutput(output / "index.html")
    check index2.contains("post1")
    check index2.contains("post2")

  test "modified tagged post triggers tag page regeneration":
    createPost(pages, "tagged", "# Original", age = 10)
    createPost(pages, "other", "# Other", age = 20)
    createTag(pages, "mytag", @["tagged"])
    buildSite(pages, output, cache, perPage = 20)

    let tagMtime = getFileInfo(output / "mytag.html").lastWriteTime
    check readOutput(output / "mytag.html").contains("Original")

    # Modify tagged post
    sleep(100)
    writeFile(pages / "tagged.md", "# Modified")
    setLastModificationTime(pages / "tagged.md", getTime())
    buildSite(pages, output, cache, perPage = 20)

    # Tag page should be regenerated
    check getFileInfo(output / "mytag.html").lastWriteTime > tagMtime
    check readOutput(output / "mytag.html").contains("Modified")

suite "Force rebuild":
  setup:
    let dir = setupTestDir()
    let pages = dir / "pages"
    let output = dir / "public"
    let cache = dir / "html"
    createDir(pages)

  teardown:
    cleanup()

  test "force flag regenerates all cache":
    createPost(pages, "post1", "# Post 1")
    createPost(pages, "post2", "# Post 2")
    buildSite(pages, output, cache, perPage = 20)

    let cache1Mtime = getFileInfo(cache / "post1.html").lastWriteTime
    let cache2Mtime = getFileInfo(cache / "post2.html").lastWriteTime

    # Wait and force rebuild
    sleep(100)
    buildSite(pages, output, cache, perPage = 20, force = true)

    # Both cache files should be regenerated
    check getFileInfo(cache / "post1.html").lastWriteTime > cache1Mtime
    check getFileInfo(cache / "post2.html").lastWriteTime > cache2Mtime

  test "force flag regenerates all output":
    createPost(pages, "post1", "# Post 1")
    createTag(pages, "tag1", @["post1"])
    buildSite(pages, output, cache, perPage = 20)

    let postMtime = getFileInfo(output / "post1.html").lastWriteTime
    let indexMtime = getFileInfo(output / "index.html").lastWriteTime
    let tagMtime = getFileInfo(output / "tag1.html").lastWriteTime

    # Wait and force rebuild
    sleep(100)
    buildSite(pages, output, cache, perPage = 20, force = true)

    # All output files should be regenerated
    check getFileInfo(output / "post1.html").lastWriteTime > postMtime
    check getFileInfo(output / "index.html").lastWriteTime > indexMtime
    check getFileInfo(output / "tag1.html").lastWriteTime > tagMtime

  test "force flag via CLI":
    createPost(pages, "post1", "# Post 1")
    let blgPath = getCurrentDir() / "blg"

    # Initial build
    let (_, exitCode1) = execCmdEx(blgPath & " -i pages -o public --cache html",
      workingDir = dir)
    check exitCode1 == 0

    let cacheMtime = getFileInfo(cache / "post1.html").lastWriteTime

    # Wait and force rebuild via CLI
    sleep(100)
    let (_, exitCode2) = execCmdEx(blgPath & " -i pages -o public --cache html --force",
      workingDir = dir)
    check exitCode2 == 0

    # Cache should be regenerated
    check getFileInfo(cache / "post1.html").lastWriteTime > cacheMtime

when isMainModule:
  # Run all tests
  discard
