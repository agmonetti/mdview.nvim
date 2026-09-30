# mdview.nvim

This is a test document. **Bold**, *italic*, and [a link](https://github.com).

## Features

- Headings at different levels
- Lists, tables, and code blocks
- [x] Real CSS rendering
- [ ] Neovim integration (next stage)

| Engine | Purpose |
| --- | --- |
| cmark-gfm | Markdown to HTML |
| litehtml | Calculates HTML/CSS layout |
| Cairo | Renders PNG |

```lua
vim.api.nvim_create_user_command('Mdview', function()
  print('Next stage')
end, {})
```

> First goal: make the PNG look like a document, not colored ANSI text.
