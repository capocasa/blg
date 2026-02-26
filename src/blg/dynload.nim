## Dynamic template loading with fallback to built-in defaults

import std/[dynlib, os, times]
import types

type
  RenderPostProc* = proc(title, content: string, date, modified: Time, menus: seq[seq[MenuItem]], tags: seq[TagInfo]): string {.nimcall.}
  RenderPageProc* = proc(title, content: string, date, modified: Time, menus: seq[seq[MenuItem]]): string {.nimcall.}
  RenderListProc* = proc(title: string, posts: seq[PostPreview], menus: seq[seq[MenuItem]], page, totalPages: int): string {.nimcall.}

  TemplateLib* = object
    lib: LibHandle
    renderPost*: RenderPostProc
    renderPage*: RenderPageProc
    renderList*: RenderListProc

proc loadTemplateLib*(path: string): TemplateLib =
  ## Load template.so if it exists, returning nil procs for fallback
  if not fileExists(path):
    return  # All procs are nil, caller uses defaults

  let lib = loadLib(path)
  if lib == nil:
    stderr.writeLine "Warning: failed to load ", path, " - using default templates"
    return

  result.lib = lib

  let postSym = lib.symAddr("renderPost")
  if postSym != nil:
    result.renderPost = cast[RenderPostProc](postSym)

  let pageSym = lib.symAddr("renderPage")
  if pageSym != nil:
    result.renderPage = cast[RenderPageProc](pageSym)

  let listSym = lib.symAddr("renderList")
  if listSym != nil:
    result.renderList = cast[RenderListProc](listSym)

proc unloadTemplateLib*(tl: var TemplateLib) =
  if tl.lib != nil:
    unloadLib(tl.lib)
    tl.lib = nil
    tl.renderPost = nil
    tl.renderPage = nil
    tl.renderList = nil

proc isLoaded*(tl: TemplateLib): bool =
  tl.lib != nil
