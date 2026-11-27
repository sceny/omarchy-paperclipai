# Omarchy's notification renderer, vendored for the tests

`Markup.js` and `Security.js` are copied unchanged from Omarchy's notification
daemon, so `test/test_model.mjs` can feed a toast body through the renderer
users run (CI has no Omarchy). Omarchy is MIT-licensed.

| File | Source | sha256 |
| --- | --- | --- |
| `Markup.js` | `/usr/share/omarchy/shell/plugins/notifications/Markup.js` | `97e37eb6e188a59df744aa135814c8cbb0257b01fa8c0ecb929f7c557aa77951` |
| `Security.js` | `/usr/share/omarchy/shell/plugins/notifications/Security.js` | `a36017c79810820a985dad06e38a2c9e547e8e650dec413b2f2cbecd063e5c95` |

Version: package `omarchy 4.5.0-3`, notifications plugin `2.0.0`
(`omarchy.notifications` manifest).

When Omarchy ships a new version of either file, copy it here, update this
table, and run `node test/test_model.mjs`.
