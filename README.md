# blg

Static blog generator. Markdown in, HTML out.

## Usage

```
blg [options]
```

**Options:**
- `-i, --input <dir>` — Input directory (default: `pages`)
- `-o, --output <dir>` — Output directory (default: `public`)
- `--cache <dir>` — Cache directory (default: `html`)
- `--per-page <n>` — Posts per page (default: 20)
- `-f, --force` — Force regenerate all
- `-d, --daemon` — Watch and rebuild on changes (Linux only)
- `-e, --env <file>` — Env file (default: `.env`)

## Structure

```
pages/
  index.md
  about.md
  post-one.md
  post-two.md
  tutorials/        # tag directory
    post-one.md -> ../post-one.md
  menu.list         # optional
```

Tags are directories containing symlinks to posts. If no `menu.list` exists, the menu defaults to index + tags alphabetically.

## Basic Mode

```
blg
```

Builds once and exits. Only regenerates changed files.

## Daemon Mode

```
blg -d
```

Builds once, then watches for changes and rebuilds automatically (5s debounce). Linux only.

## Assets

Place assets (style.css, images, etc.) directly in your output directory.

## Roadmap

- [ ] CMS style editor backend interface
