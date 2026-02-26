## Dynamic template loading with fallback to built-in defaults

import std/[dynlib, os, times]
import types

type
  # Main template procs
  RenderPostProc* = proc(title, content: string, date, modified: Time, menus: seq[seq[MenuItem]], tags: seq[TagInfo]): string {.nimcall.}
  RenderPageProc* = proc(title, content: string, date, modified: Time, menus: seq[seq[MenuItem]]): string {.nimcall.}
  RenderListProc* = proc(title: string, posts: seq[PostPreview], menus: seq[seq[MenuItem]], page, totalPages: int): string {.nimcall.}

  # Helper procs - can be overridden individually
  RenderMenuItemProc* = proc(item: MenuItem): string {.nimcall.}
  RenderHeadProc* = proc(fullTitle: string, config: SiteConfig): string {.nimcall.}
  RenderTopNavProc* = proc(topMenu: seq[MenuItem]): string {.nimcall.}
  RenderSiteHeaderProc* = proc(config: SiteConfig): string {.nimcall.}
  RenderFooterProc* = proc(bottomMenu: seq[MenuItem], hasMultipleMenus: bool): string {.nimcall.}

  TemplateLib* = object
    lib: LibHandle
    # Main templates
    renderPost*: RenderPostProc
    renderPage*: RenderPageProc
    renderList*: RenderListProc
    # Helpers
    renderMenuItem*: RenderMenuItemProc
    renderHead*: RenderHeadProc
    renderTopNav*: RenderTopNavProc
    renderSiteHeader*: RenderSiteHeaderProc
    renderFooter*: RenderFooterProc

proc loadTemplateLib*(path: string): TemplateLib =
  ## Load template.so if it exists, returning nil procs for fallback
  if not fileExists(path):
    return  # All procs are nil, caller uses defaults

  let lib = loadLib(path)
  if lib == nil:
    stderr.writeLine "Warning: failed to load ", path, " - using default templates"
    return

  result.lib = lib

  # Main templates
  let postSym = lib.symAddr("renderPost")
  if postSym != nil:
    result.renderPost = cast[RenderPostProc](postSym)

  let pageSym = lib.symAddr("renderPage")
  if pageSym != nil:
    result.renderPage = cast[RenderPageProc](pageSym)

  let listSym = lib.symAddr("renderList")
  if listSym != nil:
    result.renderList = cast[RenderListProc](listSym)

  # Helpers
  let menuItemSym = lib.symAddr("renderMenuItem")
  if menuItemSym != nil:
    result.renderMenuItem = cast[RenderMenuItemProc](menuItemSym)

  let headSym = lib.symAddr("renderHead")
  if headSym != nil:
    result.renderHead = cast[RenderHeadProc](headSym)

  let topNavSym = lib.symAddr("renderTopNav")
  if topNavSym != nil:
    result.renderTopNav = cast[RenderTopNavProc](topNavSym)

  let siteHeaderSym = lib.symAddr("renderSiteHeader")
  if siteHeaderSym != nil:
    result.renderSiteHeader = cast[RenderSiteHeaderProc](siteHeaderSym)

  let footerSym = lib.symAddr("renderFooter")
  if footerSym != nil:
    result.renderFooter = cast[RenderFooterProc](footerSym)

proc unloadTemplateLib*(tl: var TemplateLib) =
  if tl.lib != nil:
    unloadLib(tl.lib)
    tl.lib = nil
    # Main templates
    tl.renderPost = nil
    tl.renderPage = nil
    tl.renderList = nil
    # Helpers
    tl.renderMenuItem = nil
    tl.renderHead = nil
    tl.renderTopNav = nil
    tl.renderSiteHeader = nil
    tl.renderFooter = nil

proc isLoaded*(tl: TemplateLib): bool =
  tl.lib != nil
