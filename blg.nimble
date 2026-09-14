# Package
version       = "0.3.1"
author        = "Carlo Capocasa"
description   = "Static blog generator using markdown and symlinks"
license       = "MIT"
srcDir        = "src"
bin           = @["blg"]

# Dependencies
requires "nim >= 2.0.0"
requires "nmark >= 0.1.10"
requires "checksums >= 0.1.0"

task docs, "Generate documentation":
  exec "nim doc --project --index:on -o:docs/ src/blg.nim"

task test, "Run tests":
  exec "nim c -r tests/test_blg.nim"
