# GitHub Alerts

This fixture exercises the five alert types and ordinary Markdown content.

> [!NOTE]
> Useful context with **bold text**, *emphasis*, `inline code`, and café / 日本語.
>
> A second paragraph remains part of the same note.

> [!TIP]
> Keep a backup before trying the following steps.
>
> - Read the instructions.
> - Test with a small document first.

> [!IMPORTANT]
> Unsaved changes should appear in the preview without writing this file.
>
> Change this marker to `[!NOTE]` and compare the title and border.

> [!WARNING]
> This operation can overwrite existing data.
>
> ```sh
> printf 'This command is only an example.\n'
> ```

> [!CAUTION]
> Deleting your only backup can cause irreversible data loss.
>
> This longer paragraph checks wrapping in a narrow split. Scroll through its source lines and resize the preview to verify that the text remains readable and the source follows the body rather than returning to the alert title.

## Ordinary quotes stay ordinary

> An ordinary quote with **formatting**.

> \[!NOTE]
> This escaped marker stays literal.

> [!CUSTOM]
> Unknown alert types stay literal.

```markdown
> [!WARNING]
> Markers inside code stay literal.
```

## End

Close and reopen the preview; discard any probe edits with `:qall!`.
