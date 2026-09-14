## Configuration file loading for `blg.conf`.
## Strict INI format: [site] title/description, [files] extension.
## Unknown sections or keys, duplicate sections or keys, syntax errors,
## and invalid values are all fatal. Extensionless URLs need explicit
## quotes: `extension = ""`.

import std/[os, streams, parsecfg, sequtils, tables, sets]

type
  Conf* = object
    ## Settings read from blg.conf.
    siteTitle*: string        ## [site] title: site name in header and <title>
    siteDescription*: string  ## [site] description: meta description and tagline
    fileExt*: string          ## [files] extension: output extension, "" for extensionless

proc fail(path: string, line: int, msg: string) {.noreturn.} =
  echo "Error: ", path, ":", line, ": ", msg
  quit(1)

proc validExtValue(v: string): bool =
  ## Extensions are plain tokens: html, htm. No dots, slashes, spaces.
  v.allIt(it in {'a'..'z', 'A'..'Z', '0'..'9'})

proc loadConf*(path: string): Conf =
  ## Read blg.conf. A missing file yields defaults: empty title and
  ## description, "html" extension.
  result.fileExt = "html"
  if not fileExists(path):
    return

  const siteKeys = @["title", "description"]
  const fileKeys = @["extension"]

  var
    curSection = ""
    seenSections: HashSet[string]
    seenKeys: Table[string, HashSet[string]]
  let stream = newFileStream(path, fmRead)
  if stream == nil:
    echo "Error: could not read config file '", path, "'"
    quit(1)
  var p: CfgParser
  open(p, stream, path)
  defer: p.close()
  while true:
    let e = next(p)
    case e.kind
    of cfgEof:
      break
    of cfgError:
      # e.msg already carries "file(line, col) Error: ..." from parsecfg
      echo e.msg
      quit(1)
    of cfgOption:
      fail(path, p.getLine, "'--" & e.key & "' command syntax not allowed")
    of cfgSectionStart:
      if e.section != "site" and e.section != "files":
        fail(path, p.getLine,
          "unknown section [" & e.section & "], expected [site] or [files]")
      if e.section in seenSections:
        fail(path, p.getLine, "section [" & e.section & "] declared twice")
      seenSections.incl(e.section)
      seenKeys[e.section] = initHashSet[string]()
      curSection = e.section
    of cfgKeyValuePair:
      if curSection.len == 0:
        fail(path, p.getLine,
          "key '" & e.key & "' outside of a section, expected [site] or [files]")
      let allowed = if curSection == "site": siteKeys else: fileKeys
      if e.key notin allowed:
        fail(path, p.getLine,
          "unknown key '" & e.key & "' in section [" & curSection & "]")
      if e.key in seenKeys[curSection]:
        fail(path, p.getLine,
          "key '" & e.key & "' in section [" & curSection & "] declared twice")
      seenKeys[curSection].incl(e.key)
      if curSection == "site":
        if e.key == "title": result.siteTitle = e.value
        else: result.siteDescription = e.value
      elif e.value.len == 0 or validExtValue(e.value):
        result.fileExt = e.value
      else:
        fail(path, p.getLine,
          "invalid value '" & e.value & "' for extension, " &
          "use a plain token like html or \"\" for extensionless URLs")
