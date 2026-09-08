# Review notes draft

Tokly is planned as a free, local AI usage viewer for macOS 14+ on Apple Silicon. No account or purchase is required. This document is not an App Store Connect submission.

The sandbox build uses read-only user-selected directories and security-scoped bookmarks. The bundled Rust helper inherits the application's sandbox. No Full Disk Access, root privileges or external installer is required. Public pricing is downloaded separately; local conversations and usage summaries are not uploaded.

To test without installing an AI client, create a plain-text `.jsonl` file in a new folder using the following synthetic content. No explicit timestamps are included, so the existing parser uses the newly saved file's modification time. Enable only Codex, authorize that folder as its sessions directory, then start collection. Expected usage: 1.6M tokens. Actual price availability depends on the public price cache.

```jsonl
{"type":"session_meta","payload":{"id":"tokly-review-synthetic","model_provider":"openai"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-4.1","last_token_usage":{"input_tokens":1000000,"output_tokens":500000,"cached_input_tokens":200000,"reasoning_output_tokens":100000,"total_tokens":1500000},"total_token_usage":{"input_tokens":1000000,"output_tokens":500000,"cached_input_tokens":200000,"reasoning_output_tokens":100000,"total_tokens":1500000}}}}
```

After quitting and reopening, the directory grant should remain. Removing it from Sources invalidates the displayed snapshot and stops subsequent reads. Original files are not deleted. Widgets only read an application-group summary and follow system refresh scheduling.

Before submission: verify this example against the final archive; provide public support/privacy URLs; complete seller, privacy, export and distribution information. Do not submit the `local.tokensmacos.storecheck` development identity as the production app record.
