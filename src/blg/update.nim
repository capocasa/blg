## Near-silent auto-update, lifted from 3code:
##
## - On launch, fork a fully detached worker (`blg --self-update-check`)
##   that polls the GitHub releases API, downloads the matching binary
##   (a zip on Windows, bare elsewhere),
##   and atomically swaps the running binary's path. The current process
##   keeps using the old inode; the next launch picks up the new one.
## - Throttled so we hit the API at most once per 4h.
## - On the first launch after a swap, print one line on stderr.
##
## The build-time default is **off**; source-installed binaries
## (`nimble install`) shouldn't quietly self-replace what the user just
## built. CI passes `-d:autoUpdate` for prebuilt release binaries, which
## flips the default on. Either way, an explicit `BLG_AUTO_UPDATE=true`
## or `false` in the environment (or .env) wins.

import std/[httpclient, json, net, os, parseutils, strutils, times]

const autoUpdate {.booldefine.} = false

const
  Repo = "capocasa/blg"
  ThrottleSecs = 4 * 60 * 60

when defined(cacertBundle):
  # CA bundle embedded at compile time (CI release builds fetch it into
  # assets/); source builds compile without it and need no bundled trust.
  const caBundle = staticRead("../../assets/cacert.pem")
else:
  const caBundle = ""

const Asset =
  when defined(linux) and (defined(amd64) or defined(x86_64)):
    "blg-linux-amd64"
  elif defined(macosx):
    "blg-macos-universal"
  elif defined(windows) and (defined(amd64) or defined(x86_64)):
    "blg-windows-amd64.zip"
  else:
    ""  # unsupported platform: no auto-update

const BinName =
  when defined(windows): "blg.exe"
  else: "blg"

proc dataRoot(): string =
  ## App-managed state dir. `XDG_DATA_HOME` overrides the platform
  ## default, which also makes the root redirectable for tests.
  let xdg = getEnv("XDG_DATA_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".local" / "share") / "blg"

proc autoUpdateEnabled*(): bool =
  ## Explicit env var wins; otherwise the build-time default.
  let v = getEnv("BLG_AUTO_UPDATE").strip.toLowerAscii
  if v in ["true", "yes", "on", "1"]: return true
  if v in ["false", "no", "off", "0"]: return false
  autoUpdate

proc lastVersionMarker(): string = dataRoot() / "last-version"
proc updateCheckMarker(): string = dataRoot() / "last-update-check"

proc caFile(): string =
  ## macOS/Windows OpenSSL has its `OPENSSLDIR` baked to a build-runner
  ## path that doesn't exist on user systems, so verification needs an
  ## explicit CA file. Release builds embed the bundle and materialize it
  ## into the data dir; a `cacert.pem` next to the binary (older tarball
  ## installs) is the fallback. Linux uses the system trust store.
  when defined(macosx) or defined(windows):
    if caBundle.len > 0:
      try:
        createDir(dataRoot())
        result = dataRoot() / "cacert.pem"
        writeFile(result, caBundle)
      except CatchableError: discard
    if result.len == 0:
      let sibling = parentDir(getAppFilename()) / "cacert.pem"
      if fileExists(sibling): result = sibling

proc bundledSslContext(): SslContext =
  newContext(verifyMode = CVerifyPeer, caFile = caFile())

proc parseSemver*(s: string): seq[int] =
  var t = s.strip
  if t.len > 0 and t[0] == 'v': t = t[1 .. ^1]
  for part in t.split('.'):
    var n = 0
    discard parseutils.parseInt(part, n, 0)
    result.add n

proc semverGt*(a, b: string): bool =
  let pa = parseSemver(a)
  let pb = parseSemver(b)
  for i in 0 ..< max(pa.len, pb.len):
    let av = if i < pa.len: pa[i] else: 0
    let bv = if i < pb.len: pb[i] else: 0
    if av != bv: return av > bv
  false

proc throttleExpired(): bool =
  let path = updateCheckMarker()
  if not fileExists(path): return true
  try:
    let ts = readFile(path).strip.parseFloat
    return epochTime() - ts > ThrottleSecs.float
  except CatchableError:
    return true

proc touchThrottle() =
  try:
    createDir(dataRoot())
    writeFile(updateCheckMarker(), $epochTime())
  except CatchableError: discard

proc fetchLatestTag(): string =
  try:
    let client = newHttpClient(timeout = 10_000, userAgent = "blg-update",
                               sslContext = bundledSslContext())
    defer: client.close()
    let resp = client.get("https://api.github.com/repos/" & Repo &
                          "/releases/latest")
    if resp.code.int div 100 != 2: return ""
    parseJson(resp.body){"tag_name"}.getStr("")
  except CatchableError:
    ""

proc downloadAsset(tag, asset, dest: string): bool =
  let url = "https://github.com/" & Repo & "/releases/download/" &
            tag & "/" & asset
  try:
    let client = newHttpClient(timeout = 60_000, userAgent = "blg-update",
                               sslContext = bundledSslContext())
    defer: client.close()
    let resp = client.get(url)
    if resp.code.int div 100 != 2: return false
    writeFile(dest, resp.body)
    fileExists(dest) and getFileSize(dest) > 0
  except CatchableError:
    false

when defined(windows):
  proc extractArchive(archive, workDir: string): string =
    ## Extract `archive` into `workDir` (wiped first). Returns the path to
    ## the directory containing the extracted binary, or "" on failure.
    ## Win10's bsdtar autodetects zip via `tar -xf`.
    try: removeDir(workDir) except CatchableError: discard
    try: createDir(workDir) except CatchableError: return ""
    let cmd = "tar -xf " & quoteShell(archive) & " -C " & quoteShell(workDir)
    if execShellCmd(cmd) != 0: return ""
    for f in walkDirRec(workDir):
      if f.extractFilename == BinName:
        return parentDir(f)
    ""

proc swapBinary*(src, dest: string): bool =
  ## POSIX: stage the new binary as `<dest>.new` and atomic-rename it
  ## into place. The running process keeps the old inode.
  let stage = dest & ".new"
  try:
    copyFile(src, stage)
    setFilePermissions(stage, {fpUserRead, fpUserWrite, fpUserExec,
                               fpGroupRead, fpGroupExec,
                               fpOthersRead, fpOthersExec})
    moveFile(stage, dest)
    true
  except CatchableError:
    try: removeFile(stage) except CatchableError: discard
    false

when defined(windows):
  proc swapInstall*(srcDir, destBin: string): bool =
    ## Replace `destBin` and sibling runtime files (OpenSSL DLLs) with
    ## the new versions from `srcDir`. Windows can't overwrite a running
    ## exe but allows renaming it: park it as `<dest>.old`, write the new
    ## file, clean up `.old` at next launch.
    let destDir = parentDir(destBin)
    for entry in walkDir(srcDir):
      if entry.kind notin {pcFile, pcLinkToFile}: continue
      let dest = destDir / entry.path.extractFilename
      if fileExists(dest):
        let stale = dest & ".old"
        try: removeFile(stale) except CatchableError: discard
        try: moveFile(dest, stale) except CatchableError: discard
      try: copyFile(entry.path, dest)
      except CatchableError: return false
    true

proc cleanupStaleBinaries*() =
  ## Windows-only: delete `<name>.old` files left behind by `swapInstall`.
  when defined(windows):
    let dir = parentDir(getAppFilename())
    for f in walkDir(dir):
      if f.kind == pcFile and f.path.endsWith(".old"):
        try: removeFile(f.path) except CatchableError: discard

proc selfUpdateCheck*(curVersion: string, targetPath = "", force = false) =
  ## Worker entry point. Runs in the detached background process.
  ## Strictly silent: never writes to stdout/stderr.
  ##
  ## `curVersion` / `targetPath` exist for tests: they spoof the running
  ## version and binary path. `force` skips the config gate.
  if not force and not autoUpdateEnabled(): return
  if Asset.len == 0: return
  let latest = fetchLatestTag()
  if latest.len == 0: return
  if not semverGt(latest, curVersion): return
  let cache = dataRoot() / "update"
  try: createDir(cache) except CatchableError: return
  let dest = if targetPath.len > 0: targetPath else: getAppFilename()
  when defined(windows):
    # The zip carries the OpenSSL DLLs a bare exe can't do without.
    let archivePath = cache / Asset
    if not downloadAsset(latest, Asset, archivePath): return
    let srcDir = extractArchive(archivePath, cache / "extract")
    if srcDir.len == 0: return
    discard swapInstall(srcDir, dest)
    try: removeFile(archivePath) except CatchableError: discard
    try: removeDir(cache / "extract") except CatchableError: discard
  else:
    let binPath = cache / BinName
    if not downloadAsset(latest, Asset, binPath): return
    if not swapBinary(binPath, dest): return
    try: removeFile(binPath) except CatchableError: discard

when defined(posix):
  import std/posix

  proc spawnBackgroundUpdateMaybe*() =
    ## Double-fork + setsid so the worker survives the parent exiting and
    ## SIGHUP from the controlling terminal. Throttle is claimed before
    ## the fork so concurrent launches don't pile up.
    if not autoUpdateEnabled() or Asset.len == 0: return
    if not throttleExpired(): return
    touchThrottle()
    let pid = posix.fork()
    if pid < 0: return
    if pid > 0:
      var status: cint
      discard posix.waitpid(pid, status, 0)
      return
    discard posix.setsid()
    let pid2 = posix.fork()
    if pid2 < 0: quit(1)
    if pid2 > 0: quit(0)
    let fd = posix.open("/dev/null", O_RDWR)
    if fd >= 0:
      discard posix.dup2(fd, 0)
      discard posix.dup2(fd, 1)
      discard posix.dup2(fd, 2)
      if fd > 2: discard posix.close(fd)
    let exe = getAppFilename()
    let argv = allocCStringArray([exe, "--self-update-check"])
    discard posix.execv(exe.cstring, argv)
    quit(1)
elif defined(windows):
  import std/osproc

  proc spawnBackgroundUpdateMaybe*() =
    ## Windows: spawn the worker detached via `poDaemon`. Throttle is
    ## claimed before the spawn so concurrent launches don't pile up.
    if not autoUpdateEnabled() or Asset.len == 0: return
    if not throttleExpired(): return
    touchThrottle()
    try:
      let p = startProcess(getAppFilename(), args = ["--self-update-check"],
                           options = {poDaemon})
      p.close()
    except OSError: discard
else:
  proc spawnBackgroundUpdateMaybe*() = discard

proc showUpdateNoticeMaybe*(version: string) =
  ## If the recorded last-seen version differs from the running version,
  ## emit one dim line on stderr and update the marker. First launch
  ## (no marker) is silent, only writes the marker.
  let marker = lastVersionMarker()
  var prev = ""
  if fileExists(marker):
    try: prev = readFile(marker).strip
    except CatchableError: discard
  if prev.len > 0 and prev != version:
    stderr.writeLine "blg updated to " & version
  if prev != version:
    try:
      createDir(dataRoot())
      writeFile(marker, version)
    except CatchableError: discard
