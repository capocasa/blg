# Package
version       = "0.1.0"
author        = "Carlo Capocasa"
description   = "Static blog generator using markdown and symlinks"
license       = "MIT"
srcDir        = "src"
bin           = @["blg"]

# Dependencies
requires "nim >= 2.0.0"
requires "margrave >= 0.3.0"

task docs, "Generate documentation":
  exec "nim doc --project --index:on -o:docs/ src/blg.nim"
