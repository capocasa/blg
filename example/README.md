# blg example site

This is a working example that demonstrates blg's features. Open `public/index.html` in a browser to see the generated site, then follow along below.

## What you're looking at

The site has posts, pages, a tag, a custom menu, and scoped assets. Here's what each piece does.

### Posts and pages

Posts have a date on the first line and appear in the index list:

    md/hello-world.md       → post (has date, shown in list)
    md/nim-basics.md        → post
    md/web-dev-tips.md      → post

Pages are linked from the menu but don't appear in the list:

    md/about.md             → page (in menu)
    md/contact.md           → page (submenu under About)
    md/team.md              → page (submenu under About)
    md/legal.md             → page (footer menu)
    md/privacy.md           → page (footer menu)

### Tags via symlinks

Tags are directories with symlinks to posts:

    md/tutorials/
      nim-basics.md    → ../nim-basics.md
      web-dev-tips.md  → ../web-dev-tips.md

This creates a "Tutorials" tag page and nav entry. The symlinked posts appear in both the main index and the tag page.

### Custom menu

`md/menu.list` controls the nav bar:

    Index
    About
     Contact          ← indented = submenu item under About
     Team
    Tutorials

    Legal             ← after blank line = footer menu
    Privacy
    © 2026            ← plain text in footer

### Scoped CSS

These CSS files only load where they apply:

    public/post.css          → loaded on all posts (type-scoped)
    public/tutorials.css     → loaded on tutorials tag page + tagged posts
    public/hello-world.css   → loaded only on the hello-world page (slug-scoped)

Open `public/hello-world.html` — notice the gradient title from `hello-world.css`. Now open `public/nim-basics.html` — it gets `post.css` (left border) and `tutorials.css` (blue heading) but not `hello-world.css`.

### Preview truncation fix

Open `public/index.html` and look at the Hello World preview. The bold text in `hello-world.md` deliberately spans across the read-more break (triple newline). The preview is cut off mid-bold, but the closing `</strong>` tag is automatically inserted so the rest of the page renders normally.

### OG tags and RSS

Set `BLG_BASE_URL` in `.env` to enable:
- Open Graph meta tags on every page
- RSS feed at `public/feed.xml`
- Sitemap at `public/sitemap.xml`

These are commented out in this example so relative links work out of the box.

## Try it yourself

Delete the generated files and rebuild from scratch:

    rm -rf public/*.html cache/
    cd example/
    blg

Everything in `public/` except `style.css` and the scoped CSS files will be regenerated. The theme CSS is only written once on first run — edit it freely.

## Experiment

- Add a new post: create `md/my-post.md` with a date on line 1, run `blg`
- Add a tag: `mkdir md/mytag && ln -s ../my-post.md md/mytag/`, run `blg`
- Add scoped CSS: create `public/mytag.css`, run `blg -f` — it loads only on that tag's pages
- Enable absolute URLs: uncomment `BLG_BASE_URL` in `.env`, run `blg -f`
