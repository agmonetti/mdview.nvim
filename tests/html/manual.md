# Closed HTML subset — isolated preview

Before<br>after<br/>again<br />last.

Repeated café <kbd>Ctrl</kbd> + <kbd>Ctrl</kbd>, H<sub>2</sub>O,
x<sup>2</sup>, <span class="discarded">plain span &amp; Unicode: ñ 中文</span>.

<div align="center" style="color:red" data-mdview="999">
Opaque **literal Markdown**, with <kbd>keys</kbd> and &amp; entities.
Second original source line.
</div>

<div>

This paragraph is **real Markdown**, separated by blank lines.

</div>

Before <!-- complete
multiline comment --> after comment.

## Local images: Markdown and HTML must match

![Local reference](<assets/local café.png>)

<img src="assets/local café.png" alt="Local reference">

Before <img src="assets/local%20caf%C3%A9.png" alt="Inline reference"
width="1" height="1" style="display:none" onerror="ignored"
srcset="https://example.invalid/discarded.png" data-mdview="999"> after.

<div>
<img src="assets/alternate ñ.png" alt="Second local image">
</div>

Change the first HTML `src` to `assets/alternate ñ.png` without saving.
Then change it to `assets/missing.png` and back: fallback must remain visible
and correction must recover without restarting. In reader press `e` to edit,
then reopen with `:MdViewOpen replace`.

## Local image failures stay visible

<img src="assets/missing.png" alt="Missing image">

<img src="assets/corrupt.png" alt="Corrupt image">

<img src="assets/oversized.png" alt="Intrinsic width exceeds decoder budget">

<img src="https://example.invalid/never-fetch.png" alt="Remote refused">

These tags must appear as escaped literals, not disappear or abort the document.
Resize, scroll to the final heading, close and reopen the preview.

## Unsupported HTML stays visible

<details><summary>Summary</summary>Body</details>
<img src="https://example.invalid/never-fetch.png" onerror="alert(1)">
<table><tr><td>HTML table</td></tr></table>
<a href="https://example.invalid">Literal link wrapper</a>
<picture><source srcset="https://example.invalid/never-fetch.png"></picture>

## Escaped and fenced controls

\<kbd>not a key\</kbd>, `<div>inline code</div>`.

```html
<div data-mdview="999">fenced literal</div>
```

> [!NOTE]
> Alert with <kbd>keys</kbd>, x<sup>2</sup> and <span>plain text</span>.

## Recovery without hiding the rest

<div><kbd>malformed nesting</div>

Final heading and text must remain visible.
