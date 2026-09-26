# mdview.nvim — experimental Markdown renderer

A lightweight Neovim Markdown preview experiment. The repository currently converts Markdown to a PNG; it does **not** yet contain an installable Neovim plugin. Local-only agent notes and commit guidance may be present in the git-ignored `AGENTS.md`; they are not distributed with clones.

**Pipeline:** `cmark-gfm → HTML + local CSS → litehtml v0.10 + Cairo/Pango → PNG → Kitty`.

## Project status

- **Stage 1 validated:** rendered `examples/demo.md` to PNG and viewed it in Kitty.
- **Stage 2 demonstrated:** a temporary `image.nvim` setup displayed that PNG in a Neovim split. This is a manual experiment, not an implementation or committed dependency.
- Live updates, scrolling, viewport-only rendering, and a Neovim command/keymap are not implemented.

## Build on Arch Linux

```bash
sudo pacman -S --needed base-devel cmake git pkgconf cmark-gfm litehtml cairo pango gtk3
./scripts/build.sh
```

The system `litehtml` package provides the library, not its Cairo renderer. `scripts/build.sh` downloads the litehtml **v0.10** source into the ignored `third_party/litehtml/` directory to compile that adapter, then links against the system library. The adapter and library versions must remain compatible. No browser or Node.js is used.

## Render and view the fixture

```bash
./scripts/md2png examples/demo.md /tmp/mdview-demo.png 900
kitten icat /tmp/mdview-demo.png
```

Run `kitten icat` inside Kitty. To inspect only Markdown-to-HTML conversion:

```bash
./scripts/md2png --html-only examples/demo.md /tmp/mdview-demo.html
```

Temporary HTML is created beside the Markdown file so relative local image paths can resolve, then removed. The output is a **full-document image**; its dimensions and performance have not been validated for long documents.

## Current limitations

- A rendered PNG has no text selection or interactive links.
- litehtml is a layout engine, not a browser; its CSS support is partial. The current stylesheet is an initial dark theme, not a verified VS Code match.
- Code blocks are not syntax-highlighted.
- Local image formats depend on GdkPixbuf support; remote images have not been validated.
- Full-document rasterization may consume excessive memory for long files. Viewport-only rendering is a prerequisite before live updates or scrolling.
- The temporary `image.nvim` split test used ImageMagick, but ImageMagick is **not** currently a project dependency.

## Next steps

1. Clean up the static split presentation and verify resize/close cleanup.
2. Measure render time and memory on a long document; determine whether the renderer can draw only the visible viewport.
3. Only then consider live updates, scrolling, and an installable Neovim integration.

## Dependencies and references

- [cmark-gfm](https://github.com/github/cmark-gfm)
- [litehtml v0.10 Cairo adapter](https://github.com/litehtml/litehtml/tree/v0.10/containers/cairo)
- [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [image.nvim](https://github.com/3rd/image.nvim) was used only for the temporary split experiment.
