# HTML tables in mdview

This table uses the existing Markdown table styling, including a spanning header and a spanning cell.

<table class="discarded" onclick="discarded()">
<caption>Inventory &amp; status</caption>
<thead><tr><th colspan="2">Stock by region</th></tr></thead>
<tbody>
<tr><td rowspan="2">South</td><td><strong>Available</strong> — café and tools</td></tr>
<tr><td>A longer cell whose words wrap when the preview pane is made narrower; the row above should remain visible.</td></tr>
<tr><td>North</td><td>Reserved &amp; ready</td></tr>
</tbody>
<tfoot><tr><td>Total</td><td>Three rows</td></tr></tfoot>
</table>

## After table

The table above should have visible borders and the heading should follow its last row without overlap.

<details><summary>Table inside details</summary>

<table><tr><th>Key</th><th>Value</th></tr><tr><td>Inner</td><td>Open by default</td></tr></table>

</details>

## Unsupported markup stays literal

<table><tr><td colspan="0">Bad span</td></tr></table>

The invalid table should not hide this final paragraph.
