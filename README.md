# Agent title for Omarchy

A **22 px overlay** on each Cursor CLI window (`org.omarchy.agent`): the **conversation subject** Cursor already writes into the Foot title (OSC), plus the last user query on the right.

> **⚡ Built for Omarchy:** Quickshell overlay (`austraz.agent-title`). Cursor CLI has no in-TUI title bar (zen mode, composer at the bottom). Omarchy does not draw a Hyprland titlebar on that window. This fills the gap.

```
Cursor CLI Foot  →  overlay at the top  →  subject | last query | (elapsed while working)
```

---

### ☕ Support the Project
If the subject of a buried CLI session is worth a glance, a tip is always appreciated.

[![Donate via PayPal](https://img.shields.io/badge/Donate-PayPal-blue.svg?style=for-the-badge&logo=paypal)](https://paypal.me/austraz)

---

### 💬 Feedback & Community
Got a question, found a bug, or have a suggestion? Open an [**issue**](https://github.com/austrasien/omarchy-agent-title/issues).

---

## 🚀 Overview

Omarchy launches Cursor CLI in Foot with class `org.omarchy.agent`. The TUI is zen: no chrome, composer stuck at the bottom. The window title already carries the session name (`/rename`, or Cursor’s auto-name). This plugin reads Hyprland toplevels and draws a thin bar on each visible agent window.

| | Without ❌ | With Agent title ✅ |
| :--- | :--- | :--- |
| **Session name** | Only in the compositor title (easy to miss) | Accent text on the window itself |
| **Last thing you asked** | Dig through JSONL / scrollback | Right side of the bar, elided |
| **Still working?** | Watch the TUI spinner | Elapsed `(1hr 4min 10s)` while a turn is in flight |

> **Note:** This is a user plugin under `~/.config/omarchy/plugins/austraz.agent-title/`. It does not patch `/usr/share/omarchy`.

## ✨ Key Features

### 🏷 Subject from the Foot title
- Strips Cursor’s `Working…` / `Waiting for confirmation` prefixes.
- Empty or generic `foot` titles become `Cursor CLI`.
- Click the bar to focus that window.

### 💬 Last `<user_query>`
- `last-query.py` maps each Foot window to the conversation UUID `cursor-agent` has open (`store.db`), then the matching JSONL. A streaming CLI no longer steals another window’s last query.
- Poll every 2 s; also on `windowtitlev2`.
- Cache: `~/.local/state/omarchy/agent-title/queries.json`.

### ⏱ Elapsed only while a turn is running
- Shown when the JSONL is still in flight, or the OSC title is Working / confirmation.
- Hidden when the CLI is waiting at the prompt.

### 🎨 Theme
- Fill uses `Color.background`. Title uses `accent`, query uses `foreground`, from the current Omarchy `colors.toml`.

## 🛠 Installation (Omarchy)

**Requirements:** Omarchy Quattro shell (`omarchy-shell` / Quickshell), Hyprland, Cursor CLI in Foot with app-id `org.omarchy.agent`, Python 3.

```sh
omarchy plugin add https://github.com/austrasien/omarchy-agent-title.git --enable
omarchy restart shell
```

Already running a local copy?

```sh
cd ~/.config/omarchy/plugins/austraz.agent-title
git init -b main   # if needed
git remote add origin https://github.com/austrasien/omarchy-agent-title.git
git fetch origin && git reset --hard origin/main
omarchy restart shell
```

### Foot padding (keep the TUI under the bar)

The overlay is 22 px and ignores exclusive zone (`ExclusionMode.Ignore`). Give Cursor’s Foot config extra **top** pad so the TUI does not sit under the bar.

In `~/.config/foot/agent.ini` (or whichever ini `cursor-cli.desktop` passes as `--config`):

```ini
# foot 1.26+: RIGHTxTOPxLEFTxBOTTOM — commas are invalid
pad=14x22x14x14
```

`foot --check-config` must exit 0. A window already open keeps the old pad until you launch a new CLI.

### Update / remove

```sh
omarchy plugin update austraz.agent-title
omarchy plugin remove austraz.agent-title
```

If the overlay vanishes after `omarchy restart shell`: `omarchy-shell shell rescanPlugins`, then check the layer `austraz-agent-title` (`hyprctl layers`).

## ⚖️ License

Licensed under the **MIT License**.

---
*Developed so Cursor CLI sessions have a subject you can see without leaving zen mode.*
