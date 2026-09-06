# blg

![blg screenshot](docs/sc.png)
![blg screenshot 2](docs/sc2.png)

blg is a simple but enjoyable blog generator, especially for command line users. Markdown files in, blog out. Symlinks are tags. Home page: [blg.capocasa.dev](https://blg.capocasa.dev/).

# Installation

Prebuilt binaries for Linux, macOS and Windows:

    # Linux / macOS
    curl -fsSL https://blg.capocasa.dev/install.sh | sh

    # Windows (PowerShell)
    irm https://blg.capocasa.dev/install.ps1 | iex

Release binaries update themselves in the background; set
`BLG_AUTO_UPDATE=false` to opt out. From source (requires
[Nim](https://nim-lang.org/), auto-update stays off):

    nimble install blg

# Quickstart

    $ mkdir myblog && cd myblog
    $ mkdir md
    $ echo "2026-01-01

    # My first post!

    Yeah, I'm writing a post alright!
    " > md/my-first-post.md
    $ blg

Your blog is now in `public/`. Serve it with anything:

    $ rsync -av --delete public/ myuser@myserver:/var/www/myblog.net

Posts are markdown files: first line is the date, filename is the slug. Tags are directories of symlinks:

    $ mkdir md/tutorials
    $ ln -s ../my-first-post.md md/tutorials/my-first-post.md
    $ blg

Run `blg -h` for options; it fits on one screen, which is the point.

Bare URLs in your markdown are linkified automatically, so this:

    The manual is at https://blg.capocasa.dev/manual.html.

renders as a link where the URL is both the text and the href. URLs inside
code spans, fenced code blocks, and existing `[text](url)` links are left
alone.

# Documentation

The full manual (tags, pages, custom menus, pretty URLs, styling,
backgrounds, scoped assets, templating, config reference) lives at
[blg.capocasa.dev/manual.html](https://blg.capocasa.dev/manual.html).

# Changelog

```
0.2.0    Scoped assets, backgrounds, OG tags, RSS, sitemap, preview fix
0.1.0    Initial release
```

# License

MIT
