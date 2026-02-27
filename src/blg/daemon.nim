## Daemon mode with inotify file watching and debounce
## Linux-only; watches input directory and rebuilds after 5s of quiet.

import std/[os, posix, times]

const
  IN_MODIFY = 0x00000002'u32     ## File modified
  IN_CREATE = 0x00000100'u32     ## File created
  IN_DELETE = 0x00000200'u32     ## File deleted
  IN_CLOSE_WRITE = 0x00000008'u32  ## File closed after write
  IN_MOVED_TO = 0x00000080'u32   ## File moved into directory
  IN_MOVED_FROM = 0x00000040'u32 ## File moved out of directory
  DEBOUNCE_SECS = 5              ## Seconds to wait after last change

type
  InotifyEvent {.importc: "struct inotify_event", header: "<sys/inotify.h>".} = object
    ## Kernel inotify event structure.
    wd: cint
    mask: uint32
    cookie: uint32
    len: uint32

proc inotify_init(): cint {.importc, header: "<sys/inotify.h>".}
  ## Initialize inotify instance, returns file descriptor.
proc inotify_add_watch(fd: cint, path: cstring, mask: uint32): cint {.importc, header: "<sys/inotify.h>".}
  ## Add watch on path for events matching mask.

proc watchAndRebuild*(inputDir: string, rebuild: proc()) =
  ## Watch input dir for changes, call rebuild after debounce period.
  let fd = inotify_init()
  if fd < 0:
    echo "Error: failed to initialize inotify"
    quit(1)

  let mask = IN_CLOSE_WRITE or IN_CREATE or IN_DELETE or IN_MOVED_TO or IN_MOVED_FROM

  # Watch main directory
  if inotify_add_watch(fd, inputDir.cstring, mask) < 0:
    echo "Error: failed to watch ", inputDir
    quit(1)

  # Watch tags subdirectory if it exists
  let tagsDir = inputDir / "tags"
  if dirExists(tagsDir):
    discard inotify_add_watch(fd, tagsDir.cstring, mask)
    for kind, path in walkDir(tagsDir):
      if kind == pcDir:
        discard inotify_add_watch(fd, path.cstring, mask)

  echo "Watching: ", inputDir

  var buf: array[4096, char]
  var lastEvent = getTime()
  var pending = false

  # Set non-blocking read
  var flags = fcntl(fd, F_GETFL, 0)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  while true:
    let length = read(fd, addr buf[0], buf.len)

    if length > 0:
      lastEvent = getTime()
      pending = true

    if pending and (getTime() - lastEvent).inSeconds >= DEBOUNCE_SECS:
      echo "\n--- Rebuilding ---"
      rebuild()
      pending = false

    sleep(100)  # 100ms poll interval
