# token-hungry

Yet another token usage bar. There are many like it, but this one is mine.

![token-hungry in normal and Minecraft mode](demo.gif)

See your remaining usage at a quick glance in your macOS menu bar or on your Windows taskbar. On a Mac it's built on [SwiftBar](https://github.com/swiftbar/SwiftBar), with one Python file for each provider and no other dependencies. On Windows it's PowerShell, which comes with Windows, so there is nothing to install.

## Two modes

Normal mode is for people with a job.

If you want to have fun, turn on Minecraft mode. Every limit gets its own bar showing what is left: Claude's session drains your hearts and its weekly limit your golden hearts, while ChatGPT's session drains your iron armor and its weekly limit your diamond armor. An API balance shows as an item stack whose count is the dollars left (1k from a thousand on), and you pick the item (emerald, diamond, lapis lazuli, gold ingot and more, all with their own game textures). Your banked resets sit next to the bars as totems and apples. Settings… in the menu opens a window where you switch any bar off and pick what each limit is drawn with, so Claude can have hunger and ChatGPT hearts if you like. When you're down to a heart and you have no more resets left, stop prompting and touch some grass.

## Install

On macOS you need `python3`, on Windows nothing (see below), plus [Claude Code](https://claude.com/claude-code) or [Codex](https://developers.openai.com/codex) signed in (either one, or both).

Paste this into your agent:

```
Install https://github.com/alexander-posztos/token-hungry by following the install steps in its README.
```

Or do it by hand:

```sh
brew install --cask swiftbar   # then open it once and pick a plugin folder
git clone https://github.com/alexander-posztos/token-hungry
ln -s "$PWD"/token-hungry/*.5m.py "$(defaults read com.ameba.SwiftBar PluginDirectory)"
```

DeepSeek has no plan limits, so `deepseekusage.5m.py` shows your API balance instead. It reads your API key from the `DEEPSEEK_API_KEY` environment variable (on macOS, `launchctl setenv DEEPSEEK_API_KEY sk-…` so SwiftBar sees it). `openrouterusage.5m.py` does the same for OpenRouter with a management key in `OPENROUTER_API_KEY`. Leave out the plugins you don't use. To add another prepaid API, add an entry to `PROVIDERS` in `balances.py` and copy `deepseekusage.5m.py` with the new name, and for Windows add the same entry to `$providers` in `usage.ps1`.

The first time, macOS asks whether `security` may read Claude Code's login from the Keychain. Choose Always Allow.

Minecraft mode uses the [Monocraft](https://github.com/IdreesInc/Monocraft) font if you have it (`brew install --cask font-monocraft`).

### Windows

Windows needs nothing installed. `taskbar.ps1` stands in for SwiftBar and `usage.ps1` for the plugins, both in the PowerShell that ships with Windows. It draws the same titles on the taskbar of your main screen, just left of the tray icons, and clicking one opens its menu.

Download the repository (Code, Download ZIP, then unzip it) or clone it, and double-click `start.cmd`. To start it at every sign-in too, put a shortcut to `start.cmd` in your Startup folder (Win+R, `shell:startup`).

It shows Claude and ChatGPT when Claude Code or Codex is signed in on this PC, and each API balance whose key is set. Set a key once and it shows up at the next refresh, within five minutes:

```powershell
[Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', 'sk-…', 'User')
```

To show only some, pass their names: `start.cmd Claude DeepSeek`. Windows has no Keychain prompt, since Claude Code keeps its login in `%USERPROFILE%\.claude\.credentials.json` there. Install Monocraft from its [releases](https://github.com/IdreesInc/Monocraft/releases) for Minecraft mode.

## Fine print

It reads the login Claude Code and Codex already keep on your computer and sends it only to Anthropic and OpenAI. Unofficial, and not affiliated with Anthropic, OpenAI or Mojang, whose sprites are in `sprites/`. The endpoints are undocumented and can change whenever they like.

If you want cost tracking, more providers or a real app, use [CodexBar](https://github.com/steipete/CodexBar).

[MIT](LICENSE)
