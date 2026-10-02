# Details: reader and split

Text before the first disclosure.

<details>
  <summary><b>First section — click this header</b></summary>

  ### Markdown inside
  Body text with [a link](https://example.com) and **emphasis**.
  * First item
  * Second item

  <details>
    <summary>Nested section &amp; an image</summary>

  ![Local sample](assets/local%20caf%C3%A9.png)
  Nested content below the image.
  </details>

  Back in the outer block.
</details>

Between two independent blocks.

<details open style="display:none" onclick="alert(1)">
  <summary>Second section with a very long header that should wrap naturally at narrower preview widths and remain clickable on every visible header row</summary>

  > [!NOTE]
  > A note inside the second block.

  More Markdown after the note.
</details>

## After both blocks

This heading must move up when a block closes. Escaped \<details> and ` <details> ` stay literal.
