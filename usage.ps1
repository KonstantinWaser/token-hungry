# The Windows side of the plugins, for taskbar.ps1: asks Claude, ChatGPT and
# the balance providers what is left, and draws it for Minecraft mode. The
# macOS plugins (*.5m.py) do the same in Python; keep the two in step.
# ASCII only: Windows PowerShell 5.1 reads a file without a byte order mark as ANSI.
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$here = $PSScriptRoot
$invariant = [Globalization.CultureInfo]::InvariantCulture
$dot = [string][char]0xB7  # middle dot
$times = [string][char]0xD7
$warning = [string][char]0x26A0
$colors = @(@(90, '#ef4444'), @(75, '#f97316'), @(50, '#eab308'), @(0, '#22c55e'))
$green, $red = '#22c55e', '#ef4444'
$symbols = @{ USD = '$'; CNY = [string][char]0xA5; EUR = [string][char]0x20AC }

# Providers that bill per token and have an API to ask what money is left. An
# entry has the environment variable holding the API key, the URL to ask with
# it as a Bearer token, how to read the answer into balances and whether the
# money still covers calls, the page to manage it on, the page to make a key
# on and the item its Minecraft stack starts with (see $currencies).
# balances.py has the same list for macOS.
$providers = [ordered]@{
    # https://api-docs.deepseek.com/api/get-user-balance
    DeepSeek = @{
        Key = 'DEEPSEEK_API_KEY'
        Url = 'https://api.deepseek.com/user/balance'
        Read = { param($answer) @{
            Balances = @($answer.balance_infos | ForEach-Object { @{ Currency = $_.currency; Value = [double]$_.total_balance } })
            Available = [bool]$answer.is_available } }
        Page = 'https://platform.deepseek.com/usage'
        KeyPage = 'https://platform.deepseek.com/api_keys'
        Icon = 'emerald'
    }
    # https://openrouter.ai/docs/api-reference/get-credits (needs a management key)
    OpenRouter = @{
        Key = 'OPENROUTER_API_KEY'
        Url = 'https://openrouter.ai/api/v1/credits'
        Read = { param($answer) @{
            Balances = @(@{ Currency = 'USD'; Value = [double]$answer.data.total_credits - [double]$answer.data.total_usage })
            Available = [double]$answer.data.total_credits -gt [double]$answer.data.total_usage } }
        Page = 'https://openrouter.ai/settings/credits'
        KeyPage = 'https://openrouter.ai/settings/management-keys'
        Icon = 'gold_ingot'
    }
}

# --- Settings: hidden files next to this script, shared with the macOS plugins.

# A switch is on while a hidden file of its name exists.
function Test-On($name) { Test-Path -LiteralPath (Join-Path $here ".$name") }

# A setting is a hidden file holding its value.
function Get-Setting($name, $default) {
    $path = Join-Path $here ".$name"
    if (Test-Path -LiteralPath $path) { ([IO.File]::ReadAllText($path)).Trim() } else { $default }
}

# A setting's file name, from what it is about: Get-Key hide Claude Weekly is hide-claude-weekly.
function Get-Key { (($args -join '-') -replace '\W+', '-').ToLower() }

# --- Asking the providers.

function Get-Day($value) {
    if ($value -is [datetime]) { return $value.ToLocalTime() }  # pwsh 7 reads ISO dates itself
    [DateTimeOffset]::Parse($value, $invariant).LocalDateTime
}

function Format-Day($day) { $day.ToString('d MMM', $invariant) }

function Format-Countdown([long]$secs) {
    $d = [Math]::Floor($secs / 86400); $h = [Math]::Floor($secs % 86400 / 3600); $m = [Math]::Floor($secs % 3600 / 60)
    if ($d) { "${d}d ${h}h" } elseif ($h) { "${h}h ${m}m" } else { "${m}m" }
}

function Get-Status($errorRecord) {
    $response = $errorRecord.Exception.Response
    if ($response) { [int]$response.StatusCode } else { 0 }
}

# GETs a URL with a Bearer token and returns the body as text.
function Invoke-Get($url, $token, $agent = 'token-hungry') {
    $response = Invoke-WebRequest -Uri $url -Headers @{ Authorization = "Bearer $token" } -UserAgent $agent -UseBasicParsing -TimeoutSec 20
    [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
}

# Banked resets as menu lines, from (name, usable from, expires) as ISO dates,
# either of which can be missing. Resets of one kind share a line.
function Group-Resets($resets) {
    $groups = [ordered]@{}
    foreach ($reset in $resets) {
        $line = (Get-Culture).TextInfo.ToTitleCase("$($reset[0])".ToLower()) + ' reset'
        if ($reset[1] -and (Get-Day $reset[1]) -gt (Get-Date)) { $line += ' from ' + (Format-Day (Get-Day $reset[1])) }
        if (-not $groups.Contains($line)) { $groups[$line] = New-Object Collections.ArrayList }
        [void]$groups[$line].Add($(if ($reset[2]) { Format-Day (Get-Day $reset[2]) } else { '' }))
    }
    foreach ($line in $groups.Keys) {
        $until = @($groups[$line] | Where-Object { $_ } | Select-Object -Unique) -join " $dot "
        @{ Count = $groups[$line].Count; Kind = ($line -split ' ')[0]; Text = $line + $(if ($until) { " until $until" }) }
    }
}

# Claude Code's user agent with the installed version, since Anthropic stops
# returning banked resets to versions that have grown old.
function Get-ClaudeAgent {
    $version = '2.1.323'  # claimed when the claude command is missing
    try { $installed = ("$(& claude --version 2>$null)" -split ' ')[0]; if ($installed) { $version = $installed } } catch { }
    "claude-cli/$version (external, cli)"
}

# The endpoint behind Claude Code's /usage. It rate-limits each account, and
# Claude Code asks it too, so the last answer is kept and shown again while it
# says 429.
# A login file as an object. Windows PowerShell 5.1 puts the whole text in its
# parse error, tokens and all, and errors are shown in the menu, so a file
# caught half-written only says it could not be read.
function Read-Login($path) {
    try { [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw "Cannot read the login in $path" }
}

function Get-Claude {
    $token = (Read-Login (Join-Path $HOME '.claude\.credentials.json')).claudeAiOauth.accessToken
    $cache = Join-Path $here '.claude-usage.json'
    $note = $null
    try {
        $text = Invoke-Get 'https://api.anthropic.com/api/oauth/usage?cedar_ember=1' $token (Get-ClaudeAgent)
        $usage = $text | ConvertFrom-Json
        [IO.File]::WriteAllText($cache, $text)  # once it parsed; no byte order mark, the macOS plugin reads it too
    } catch {
        if ((Get-Status $_) -ne 429 -or -not (Test-Path $cache)) { throw }
        $usage = [IO.File]::ReadAllText($cache) | ConvertFrom-Json
        $note = 'Rate limited, as of ' + (Get-Item $cache).LastWriteTime.ToString('HH:mm')
    }
    $rows = foreach ($limit in $usage.limits) {
        $label = @{ session = 'Session'; weekly_all = 'Weekly' }[$limit.kind]
        if (-not $label) { continue }  # ponytail: per-model limits left out; read $limit.scope.model to bring them back
        $secs = if ($limit.resets_at) { [long]((Get-Day $limit.resets_at) - (Get-Date)).TotalSeconds } else { 0 }
        @{ Label = $label; Pct = [int][Math]::Round([double]$limit.percent); Secs = $secs }
    }
    $resets = New-Object Collections.ArrayList
    foreach ($grant in @($usage.cedar_ember.grants | Where-Object { $_ })) {
        for ($i = 0; $i -lt $grant.resets_left; $i++) { [void]$resets.Add(@($grant.type, $grant.starts_at, $grant.ends_at)) }
    }
    @{ Rows = @($rows); Resets = @(Group-Resets $resets); Note = $note
       Links = @(, @('Usage settings', 'https://claude.ai/settings/usage')) }
}

# The endpoint behind Codex's /status.
function Get-ChatGPT {
    $token = (Read-Login (Join-Path $HOME '.codex\auth.json')).tokens.access_token
    $url = 'https://chatgpt.com/backend-api/wham/'
    $usage = Invoke-Get "${url}usage" $token | ConvertFrom-Json
    $rows = foreach ($window in @($usage.rate_limit.primary_window, $usage.rate_limit.secondary_window) | Where-Object { $_ }) {
        @{ Label = $(if ($window.limit_window_seconds -gt 86400) { 'Weekly' } else { 'Session' })
           Pct = [int][Math]::Round([double]$window.used_percent); Secs = [long]$window.reset_after_seconds }
    }
    $resets = New-Object Collections.ArrayList
    if ($usage.rate_limit_reset_credits.available_count) {
        $credits = (Invoke-Get "${url}rate-limit-reset-credits" $token | ConvertFrom-Json).credits
        foreach ($credit in $credits | Where-Object { $_.status -eq 'available' }) {
            [void]$resets.Add(@(($credit.title -split ' ')[0], $null, $credit.expires_at))
        }
    }
    @{ Rows = @($rows); Resets = @(Group-Resets $resets); Links = @() }
}

# The key is read from the user's environment too, so a key set after the
# taskbar started works without a restart.
function Get-ApiKey($name) {
    $key = [Environment]::GetEnvironmentVariable($name)
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable($name, 'User') }
    $key
}

# Keeps a key for good (the user's environment) and for this process, so the
# next refresh sees it without a restart.
function Set-ApiKey($name, $value) {
    [Environment]::SetEnvironmentVariable($name, $value, 'User')
    [Environment]::SetEnvironmentVariable($name, $value)
}

function Get-Balance($name) {
    $provider = $providers[$name]
    $key = Get-ApiKey $provider.Key
    if (-not $key) { throw "Set $($provider.Key) to your $name API key" }
    $read = & $provider.Read (Invoke-Get $provider.Url $key | ConvertFrom-Json)
    @{ Balances = $read.Balances; Available = $read.Available; Links = @(, @('Usage', $provider.Page)) }
}

# The sources to show: each one whose login or key is on this PC, or those named.
function Get-Sources($names) {
    $all = [ordered]@{
        Claude = @{ Fetch = { Get-Claude }; Ready = { Test-Path (Join-Path $HOME '.claude\.credentials.json') } }
        ChatGPT = @{ Fetch = { Get-ChatGPT }; Ready = { Test-Path (Join-Path $HOME '.codex\auth.json') } }
    }
    foreach ($name in $providers.Keys) {
        $all[$name] = @{ Fetch = [scriptblock]::Create("Get-Balance '$name'"); Ready = [scriptblock]::Create("[bool](Get-ApiKey '$($providers[$name].Key)')") }
    }
    foreach ($name in $all.Keys) {
        if ($(if ($names) { $names -contains $name } else { & $all[$name].Ready })) {
            @{ Name = $name; Fetch = $all[$name].Fetch; Model = $null }
        }
    }
}

# A model is what a source said: usage rows, banked resets and balances, links
# for the menu, or the error that kept it from saying anything.
function Update-Model($source) {
    try { $source.Model = & $source.Fetch } catch { $source.Model = @{ Error = $_.Exception.Message } }
}

function Get-UsageColor($pct) { ($colors | Where-Object { $pct -ge $_[0] } | Select-Object -First 1)[1] }

function Format-Money($balance) {
    $symbol = if ($symbols[$balance.Currency]) { $symbols[$balance.Currency] } else { "$($balance.Currency) " }
    $symbol + $balance.Value.ToString('0.00', $invariant)
}

function Format-UsageRow($row, [switch]$Bar) {
    $filled = [Math]::Min(10, [int][Math]::Round($row.Pct / 10))
    $blocks = if ($Bar) { ([string][char]0x2588) * $filled + ([string][char]0x2591) * (10 - $filled) + ' ' } else { '' }
    $reset = if ($row.Secs) { '   resets in ' + (Format-Countdown $row.Secs) } else { '' }
    '{0,-8}{1}{2,3}%{3}' -f $row.Label, $blocks, $row.Pct, $reset
}

# --- Minecraft mode. A picture is a 32-bit ARGB bitmap, drawn pixel for pixel.

$bars = [ordered]@{
    'Hearts' = 'container', 'half', 'full'
    'Golden hearts' = 'container', 'absorbing_half', 'absorbing_full'
    'Poisoned hearts' = 'container', 'poisoned_half', 'poisoned_full'
    'Withered hearts' = 'container', 'withered_half', 'withered_full'
    'Frozen hearts' = 'container', 'frozen_half', 'frozen_full'
    'Hardcore hearts' = 'container_hardcore', 'hardcore_half', 'hardcore_full'
    'Hardcore golden hearts' = 'container_hardcore', 'absorbing_hardcore_half', 'absorbing_hardcore_full'
    'Hardcore poisoned hearts' = 'container_hardcore', 'poisoned_hardcore_half', 'poisoned_hardcore_full'
    'Hardcore withered hearts' = 'container_hardcore', 'withered_hardcore_half', 'withered_hardcore_full'
    'Hardcore frozen hearts' = 'container_hardcore', 'frozen_hardcore_half', 'frozen_hardcore_full'
    'Mount hearts' = 'vehicle_container', 'vehicle_half', 'vehicle_full'
    'Hunger' = 'food_empty', 'food_half', 'food_full'
    'Hunger effect' = 'food_empty_hunger', 'food_half_hunger', 'food_full_hunger'
    'Air' = 'air_empty', 'air_bursting', 'air'
}
foreach ($material in 'leather', 'chainmail', 'copper', 'iron', 'gold', 'diamond', 'netherite') {
    $bars["$((Get-Culture).TextInfo.ToTitleCase($material)) armor"] = 'armor_empty', "armor_${material}_half", "armor_${material}_full"
}
# The bar each limit has until the user picks another in the settings.
$defaultBars = @{ 'Claude-Session' = 'Hearts'; 'Claude-Weekly' = 'Golden hearts'
                  'ChatGPT-Session' = 'Iron armor'; 'ChatGPT-Weekly' = 'Diamond armor' }
$items = @{ Session = 'apple'; Weekly = 'golden_apple'; Full = 'totem_of_undying' }
# The items a balance can be shown as: Minecraft's own textures, in sprites/.
$currencies = 'emerald', 'diamond', 'lapis_lazuli', 'amethyst_shard', 'redstone', 'quartz',
              'gold_ingot', 'iron_ingot', 'copper_ingot', 'netherite_ingot', 'gold_nugget', 'iron_nugget'
$menuBar = 44  # pixels a title may be tall: the macOS menu bar's 22 points at 2x, which looks right here too
# Armor is drawn: outline (o) to highlight (h), in each material's colors.
$armor = 'ooo...ooo', 'ohlo.olmo', 'ohllollmo', 'ollllllmo', '.ollllmo.', '.ollllmo.', '.ollllmo.', '.ommmmmo.', '.ooooooo.'
$palettes = @{  # outline, dark, mid, light, highlight
    leather = '#321c0e', '#734020', '#a06540', '#c68b5e', '#e0b48c'
    chainmail = '#1e1e1e', '#464646', '#6e6e6e', '#969696', '#bebebe'
    copper = '#3c1e12', '#9c4e31', '#d87a55', '#e79c78', '#fac8aa'
    gold = '#3c2d05', '#c88c14', '#fad232', '#fff078', '#ffffc8'
    netherite = '#141012', '#31292a', '#443a3b', '#5f5254', '#827375'
    diamond = '#0e3f42', '#209ea3', '#4adcd4', '#a1fbe8', '#ebfffc'
    iron = '#242424', '#8c8c8c', '#c8c8c8', '#e2e2e2', '#ffffff'
    empty = '#242424', '#3c3c3c', '#3c3c3c', '#484848', '#585858'
}
# Letters for big stack counts, in the style of the digit sprite.
$glyphs = @{
    k = '#....', '#....', '#..#.', '#.#..', '##...', '#.#..', '#..#.'
    M = '#...#', '##.##', '#.#.#', '#...#', '#...#', '#...#', '#...#'
}

function Get-Bar($name, $label) {
    $default = $defaultBars["$name-$label"]
    Get-Setting (Get-Key bar $name $label) $(if ($default) { $default } else { 'Hearts' })
}

function New-Picture($width, $height) {
    New-Object Drawing.Bitmap ([Math]::Max(1, $width)), ([Math]::Max(1, $height)), ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
}

# Draws `other` onto `picture` with its corner at (left, top), `scale` times as large.
function Add-Picture($picture, $other, $left = 0, $top = 0, $scale = 1) {
    $graphics = [Drawing.Graphics]::FromImage($picture)
    $graphics.InterpolationMode = 'NearestNeighbor'
    $graphics.PixelOffsetMode = 'Half'
    $graphics.DrawImage($other, (New-Object Drawing.Rectangle $left, $top, ([int]($other.Width * $scale)), ([int]($other.Height * $scale))))
    $graphics.Dispose()
}

function Resize-Picture($picture, $scale) {
    $large = New-Picture ([int]($picture.Width * $scale)) ([int]($picture.Height * $scale))
    Add-Picture $large $picture 0 0 $scale
    $large
}

# A picture from rows of letters, each letter a color.
function New-Drawing($rows, $colorOf) {
    $picture = New-Picture $rows[0].Length $rows.Count
    for ($y = 0; $y -lt $rows.Count; $y++) {
        for ($x = 0; $x -lt $rows[$y].Length; $x++) {
            $color = $colorOf[[string]$rows[$y][$x]]
            if ($color) { $picture.SetPixel($x, $y, $color) }
        }
    }
    $picture
}

$sprites = @{}
# A sprite: drawn armor (armor_empty, armor_<material>_full or _half) or a PNG in sprites/.
function Get-Sprite($name) {
    if ($sprites[$name]) { return $sprites[$name] }
    if ($name -like 'armor_*') {
        $material, $size = $name.Substring(6) -split '_'
        $colorOf = @{}
        for ($i = 0; $i -lt 5; $i++) { $colorOf['odmlh'[$i].ToString()] = [Drawing.ColorTranslator]::FromHtml($palettes[$material][$i]) }
        $rows = if ($size -eq 'half') { $armor | ForEach-Object { $_.Substring(0, 5) + '....' } } else { $armor }
        $picture = New-Drawing $rows $colorOf
    } else {
        $file = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes((Join-Path $here "sprites\$name.png")))))
        $picture = New-Picture $file.Width $file.Height
        Add-Picture $picture $file
    }
    $sprites[$name] = $picture
    $picture
}

# A bar of icons showing what is left of a limit.
function Get-Icons { if (Test-On wide) { 10 } else { 5 } }

# The half icons left of a limit.
function Get-Halves($pct) { [Math]::Round((100 - [Math]::Min(100, $pct)) * 2 * (Get-Icons) / 100) }

# A look animates a bar on the taskbar: Blink draws it white, as when the
# player takes damage, and Lift raises each icon by that many pixels. A bar
# with a look, even an empty one, gets two pixels of room above it.
function New-Bar($style, $pct, $look = $null) {
    $empty, $half, $full = $bars[$style]
    $icons = Get-Icons
    $halves = Get-Halves $pct
    $room = if ($null -ne $look) { 2 } else { 0 }
    $bar = New-Picture (8 * $icons + 1) (9 + $room)
    for ($i = 0; $i -lt $icons; $i++) {
        $top = $room - $(if ($look.Lift) { $look.Lift[$i] } else { 0 })
        Add-Picture $bar (Get-Look $empty $look.Blink) (8 * $i) $top
        if ($halves -ge 2 * $i + 1) { Add-Picture $bar (Get-Look $(if ($halves -ge 2 * $i + 2) { $full } else { $half }) $look.Blink) (8 * $i) $top }
    }
    $bar
}

# A sprite, or blinking: the game's own blinking heart where there is one,
# anything else lightened.
function Get-Look($name, $blink) {
    if (-not $blink) { return Get-Sprite $name }
    if (Test-Path -LiteralPath (Join-Path $here "sprites\${name}_blinking.png")) { return Get-Sprite "${name}_blinking" }
    if (-not $sprites["$name*"]) {
        $plain = Get-Sprite $name
        $matrix = New-Object Drawing.Imaging.ColorMatrix
        $matrix.Matrix40 = $matrix.Matrix41 = $matrix.Matrix42 = 0.5
        $attributes = New-Object Drawing.Imaging.ImageAttributes
        $attributes.SetColorMatrix($matrix)
        $light = New-Picture $plain.Width $plain.Height
        $graphics = [Drawing.Graphics]::FromImage($light)
        $graphics.DrawImage($plain, (New-Object Drawing.Rectangle 0, 0, $plain.Width, $plain.Height), 0, 0, $plain.Width, $plain.Height, 'Pixel', $attributes)
        $graphics.Dispose()
        $sprites["$name*"] = $light
    }
    $sprites["$name*"]
}

# The taskbar title: the bars side by side or stacked, then the items, drawn as
# large as still fits.
function New-Title($barPictures, $itemPictures) {
    $barPictures = @($barPictures | Where-Object { $_ }); $itemPictures = @($itemPictures | Where-Object { $_ })
    $width = ($barPictures | ForEach-Object { $_.Width } | Measure-Object -Maximum).Maximum
    $tall = if ($barPictures.Count) { $barPictures[0].Height } else { 9 }  # 11 with room for a look
    if (Test-On stacked) { $across, $down = 0, ($tall + 1) } else { $across, $down = ($width + 5), 0 }
    $count = $barPictures.Count
    $barsWidth = if ($count) { $width + $across * ($count - 1) } else { 0 }
    $barsHeight = if ($count) { $tall + $down * ($count - 1) } else { 0 }
    $gap = if ($count -and $itemPictures.Count) { 4 } else { 0 }
    $height = [Math]::Max($barsHeight, $(if ($itemPictures.Count) { 18 } else { 0 }))
    $itemsWidth = ($itemPictures | ForEach-Object { $_.Width } | Measure-Object -Sum).Sum
    $strip = New-Picture ($barsWidth + $gap + $itemsWidth) $height
    for ($i = 0; $i -lt $count; $i++) {
        Add-Picture $strip $barPictures[$i] ($across * $i) ([Math]::Floor(($height - $barsHeight) / 2) + $down * $i)
    }
    $left = $barsWidth + $gap
    foreach ($item in $itemPictures) { Add-Picture $strip $item $left; $left += $item.Width }
    Resize-Picture $strip ([Math]::Max(1, [Math]::Min(3, [Math]::Floor($menuBar / $height))))
}

# The experience bar, filled to the percent used.
function New-Experience($pct) {
    $bar = New-Picture 182 5
    Add-Picture $bar (Get-Sprite experience_bar_background)
    $filled = [int][Math]::Round(182 * [Math]::Min(100, $pct) / 100)
    if ($filled) {
        $graphics = [Drawing.Graphics]::FromImage($bar)
        $graphics.DrawImage((Get-Sprite experience_bar_progress), (New-Object Drawing.Rectangle 0, 0, $filled, 5), 0, 0, $filled, 5, 'Pixel')
        $graphics.Dispose()
    }
    $bar
}

# A stack size as the game would print it, shortened from a thousand on: 1k,
# 12k, 3M. A balance below zero is an empty stack.
function Format-Amount([double]$value) {
    $value = [Math]::Max(0, $value)
    foreach ($size in @(@(1000000, 'M'), @(1000, 'k'))) {
        if ([Math]::Round($value) -ge $size[0]) { return '{0}{1}' -f [Math]::Round($value / $size[0]), $size[1] }
    }
    '{0}' -f [Math]::Round($value)
}

# An item in its slot with a count in the corner, as in the inventory. A long
# count widens the slot to the left, as a stack of 64 overhangs its item.
function New-Slot($name, $count = '') {
    $text = New-Picture (6 * $count.Length - 1) 7
    $white = @{ '#' = [Drawing.Color]::White }
    for ($i = 0; $i -lt $count.Length; $i++) {
        $c = [string]$count[$i]
        if ($c -match '\d') {
            $graphics = [Drawing.Graphics]::FromImage($text)
            $graphics.DrawImage((Get-Sprite digits), (New-Object Drawing.Rectangle (6 * $i), 0, 5, 7), (8 * [int]$c), 0, 5, 7, 'Pixel')
            $graphics.Dispose()
        } else {
            Add-Picture $text (New-Drawing $glyphs[$c] $white) (6 * $i)
        }
    }
    $width = [Math]::Max(18, $text.Width + 2)
    $slot = New-Picture $width 18
    Add-Picture $slot (Get-Sprite $name) ($width - 18)
    if ($count) {
        $shadow = New-Picture $text.Width $text.Height
        for ($y = 0; $y -lt $text.Height; $y++) {
            for ($x = 0; $x -lt $text.Width; $x++) {
                if ($text.GetPixel($x, $y).A) { $shadow.SetPixel($x, $y, [Drawing.Color]::FromArgb(63, 63, 63)) }
            }
        }
        Add-Picture $slot $shadow ($width - $text.Width - 1) 10
        Add-Picture $slot $text ($width - $text.Width - 2) 9
    }
    $slot
}

# A model drawn the Minecraft way: the title picture, or $null when there is
# nothing to draw, and for each menu row a picture to show beside it.
# Looks, when given, map a row's label to its look (see New-Bar); the taskbar
# always gives them, so the title keeps its size while it animates.
function New-MinecraftTitle($name, $model, $looks = $null) {
    $barPictures = foreach ($row in $model.Rows) {
        $look = if ($null -eq $looks) { $null } elseif ($looks[$row.Label]) { $looks[$row.Label] } else { @{} }
        if (-not (Test-On (Get-Key hide $name $row.Label))) { New-Bar (Get-Bar $name $row.Label) $row.Pct $look }
    }
    $itemPictures = @(
        foreach ($balance in $model.Balances) {
            if (-not (Test-On (Get-Key hide $name Balance))) { New-Slot (Get-Currency $name) (Format-Amount $balance.Value) }
        }
        foreach ($reset in $model.Resets) {
            if (-not (Test-On (Get-Key hide $name Resets))) { New-Slot (Get-ResetItem $reset.Kind) $(if ($reset.Count -gt 1) { "$($reset.Count)" } else { '' }) }
        })
    if (@($barPictures | Where-Object { $_ }).Count -or $itemPictures.Count) { New-Title $barPictures $itemPictures }
}

function Get-Currency($name) { Get-Setting (Get-Key icon $name) $providers[$name].Icon }
function Get-ResetItem($kind) { if ($items[$kind]) { $items[$kind] } else { 'golden_apple' } }
