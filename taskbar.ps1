# token-hungry for Windows, with nothing to install: draws what is left of
# each limit on the taskbar, left of the tray, the way SwiftBar draws the
# macOS plugins in the menu bar. Clicking a title opens its menu.
# Start it with start.cmd. Pass names to show only those: start.cmd Claude DeepSeek
# ASCII only: Windows PowerShell 5.1 reads a file without a byte order mark as ANSI.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// A borderless, always-on-top window drawn from a bitmap with per-pixel alpha.
public class Strip : Form {
    [StructLayout(LayoutKind.Sequential)] struct Pt { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct Sz { public int W, H; }
    [StructLayout(LayoutKind.Sequential)] public struct Rc { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Blend { public byte Op, Flags, Alpha, Format; }
    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr w, IntPtr dst, ref Pt at, ref Sz size, IntPtr src, ref Pt from, int key, ref Blend blend, int flags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr w);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr w, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr w, IntPtr after, int x, int y, int cx, int cy, int flags);
    [DllImport("user32.dll")] static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr w, out Rc r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr w);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResourceEx(string file, int flags, IntPtr reserved);

    public Strip() { FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams p = base.CreateParams;
            p.ExStyle |= 0x80000 | 0x80 | 0x8 | 0x8000000;  // layered, tool window, topmost, no activate
            return p;
        }
    }

    public void Draw(Bitmap bitmap, int x, int y) {
        IntPtr screen = GetDC(IntPtr.Zero), memory = CreateCompatibleDC(screen);
        IntPtr handle = bitmap.GetHbitmap(Color.FromArgb(0)), old = SelectObject(memory, handle);
        Pt at = new Pt { X = x, Y = y }, from = new Pt();
        Sz size = new Sz { W = bitmap.Width, H = bitmap.Height };
        Blend blend = new Blend { Alpha = 255, Format = 1 };
        UpdateLayeredWindow(Handle, screen, ref at, ref size, memory, ref from, 0, ref blend, 2);
        SelectObject(memory, old); DeleteObject(handle); DeleteDC(memory); ReleaseDC(IntPtr.Zero, screen);
    }

    // The taskbar raises itself over topmost windows when clicked.
    public void KeepOnTop() { SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x13); }

    // Puts the strip back over the taskbar the moment the taskbar or anything
    // else comes forward, instead of polling for it.
    delegate void WinEvent(IntPtr hook, uint ev, IntPtr w, int obj, int child, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEvent proc, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr w, uint relation);
    WinEvent onEvent;  // held here so the collector keeps it
    public void FollowTaskbar() {
        onEvent = (hook, ev, w, obj, child, thread, time) => { if (w != Handle && !AboveTaskbar()) KeepOnTop(); };
        SetWinEventHook(0x3, 0x3, IntPtr.Zero, onEvent, 0, 0, 0);        // foreground changed
        SetWinEventHook(0x8004, 0x8004, IntPtr.Zero, onEvent, 0, 0, 0);  // z-order changed
    }
    public bool AboveTaskbar() {
        for (IntPtr w = GetWindow(FindWindow("Shell_TrayWnd", null), 3); w != IntPtr.Zero; w = GetWindow(w, 3)) {
            if (w == Handle) return true;  // walking up from the taskbar (3: the window above)
        }
        return false;
    }

    // The tray area of the main taskbar, or the taskbar itself without one.
    public static Rc Tray() {
        IntPtr bar = FindWindow("Shell_TrayWnd", null);
        IntPtr tray = FindWindowEx(bar, IntPtr.Zero, "TrayNotifyWnd", null);
        Rc r; GetWindowRect(tray != IntPtr.Zero ? tray : bar, out r);
        return r;
    }
}
'@
. (Join-Path $PSScriptRoot 'usage.ps1')

$running = New-Object Threading.Mutex($false, 'token-hungry-taskbar')
if (-not $running.WaitOne(0)) { exit }  # already on the taskbar

# Monocraft ships in fonts/ and is loaded for this process only, so it needs no
# install: GDI+ draws from the collection, the menus (GDI) from the resource.
$fonts = New-Object Drawing.Text.PrivateFontCollection
$fontFile = Join-Path $PSScriptRoot 'fonts\Monocraft.ttf'
$fonts.AddFontFile($fontFile)
[void][Strip]::AddFontResourceEx($fontFile, 0x10, [IntPtr]::Zero)  # 0x10: private to this process
$monocraft = $fonts.Families[0]
# ponytail: theme read once at start; restart after switching light/dark
$light = (Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize -ErrorAction SilentlyContinue).SystemUsesLightTheme -eq 1
$ink = if ($light) { [Drawing.Color]::Black } else { [Drawing.Color]::White }
$menuScale = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96  # menu pictures at twice their pixels on a 192 dpi screen

# The Claude and ChatGPT logos come from the macOS plugins, as masks that get
# the taskbar's text color.
function Get-Logo($file) {
    $base64 = [regex]::Match([IO.File]::ReadAllText((Join-Path $here $file)), 'ICON = "([^"]+)"').Groups[1].Value
    $source = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [Convert]::FromBase64String($base64))))
    $image = New-Object Drawing.Bitmap $source.Width, $source.Height
    $matrix = New-Object Drawing.Imaging.ColorMatrix
    $matrix.Matrix00 = $matrix.Matrix11 = $matrix.Matrix22 = 0
    $matrix.Matrix40 = $ink.R / 255; $matrix.Matrix41 = $ink.G / 255; $matrix.Matrix42 = $ink.B / 255
    $attributes = New-Object Drawing.Imaging.ImageAttributes
    $attributes.SetColorMatrix($matrix)
    $graphics = [Drawing.Graphics]::FromImage($image)
    $graphics.DrawImage($source, (New-Object Drawing.Rectangle 0, 0, $source.Width, $source.Height), 0, 0, $source.Width, $source.Height, 'Pixel', $attributes)
    $image
}
$logos = @{ Claude = Get-Logo 'claudeusage.5m.py'; ChatGPT = Get-Logo 'gptusage.5m.py' }

function Add-Row($menu, $text, $color = $null, $picture = $null, $action = $null, [switch]$Checked) {
    $item = New-Object Windows.Forms.ToolStripMenuItem $text
    $item.Font = if (Test-On minecraft) { New-Object Drawing.Font $monocraft, 10 } else { New-Object Drawing.Font 'Consolas', 10 }
    if ($color) { $item.ForeColor = [Drawing.ColorTranslator]::FromHtml($color) }
    # ponytail: WinForms only draws pictures in the left margin, SwiftBar puts them after the text
    if ($picture) { $item.Image = Resize-Picture $picture $menuScale; $item.ImageScaling = 'None' }
    if ($action) { $item.Add_Click($action) }
    $item.Checked = [bool]$Checked
    [void]$menu.Items.Add($item)
}

function Add-Line($menu) { [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) }

# Draws a source's title and fills its menu from what it last said.
function Show-Source($source) {
    $name, $model, $menu = $source.Name, $source.Model, $source.Menu
    $minecraft = Test-On minecraft
    $balance = $providers.Contains($name)
    $source.Image = $null; $source.Text = ''; $source.Color = $ink
    if ($minecraft -and -not $model.Error) {
        $looks = Get-Looks $source
        $source.LookKey = $looks | ConvertTo-Json -Compress -Depth 3
        $source.Image = New-MinecraftTitle $name $model $looks
        $source.Frames = @{ $source.LookKey = $source.Image }  # frames drawn for this model and these settings, by look
    }
    if (-not $source.Image) {
        if ($balance) {
            $source.Text = "$($name[0]) " + $(if ($model.Error) { $warning } else { Format-Money $model.Balances[0] })
            if (-not $model.Error) { $source.Color = [Drawing.ColorTranslator]::FromHtml($(if ($model.Available) { $green } else { $red })) }
        } else {
            $source.Image = $logos[$name]
            $source.Text = if ($model.Error) { $warning } else { @($model.Rows | ForEach-Object { "$($_.Label[0]) $($_.Pct)%" }) -join " $dot " }
        }
    }

    $menu.Items.Clear()
    if ($minecraft) { Add-Row $menu "$name usage" }
    if ($model.Error) { Add-Row $menu $model.Error }
    foreach ($row in $model.Rows) {
        if ($minecraft) { Add-Row $menu (Format-UsageRow $row) (Get-UsageColor $row.Pct) (New-Experience $row.Pct) }
        else { Add-Row $menu (Format-UsageRow $row -Bar) (Get-UsageColor $row.Pct) }
    }
    foreach ($money in $model.Balances) {
        $picture = if ($minecraft) { New-Slot (Get-Currency $name) (Format-Amount $money.Value) }
        Add-Row $menu ('{0,-10}{1,10}' -f 'Balance', (Format-Money $money)) $(if ($model.Available) { $green } else { $red }) $picture
    }
    if ($model.Resets) { Add-Line $menu }
    foreach ($reset in $model.Resets) {
        if ($minecraft) { Add-Row $menu $reset.Text $null (New-Slot (Get-ResetItem $reset.Kind) $(if ($reset.Count -gt 1) { "$($reset.Count)" } else { '' })) }
        else { Add-Row $menu "$($reset.Count)$times $($reset.Text)" }
    }
    Add-Line $menu
    if ($model.Note) { Add-Row $menu $model.Note '#9ca3af' }
    foreach ($link in $model.Links) { Add-Row $menu $link[0] $null $null ([scriptblock]::Create("Start-Process '$($link[1])'")) }
    Add-Row $menu 'Refresh' $null $null { Update-All }
    Add-Line $menu
    Add-Row $menu 'Minecraft' $null $null { Switch-Setting minecraft; Show-All } -Checked:$minecraft
    Add-Row $menu 'Settings...' $null $null { Show-Settings }
    Add-Row $menu 'Quit' $null $null { [Windows.Forms.Application]::Exit() }
}

function Switch-Setting($name) {
    $path = Join-Path $here ".$name"
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } else { [IO.File]::WriteAllText($path, '') }
}

# The settings window: the switches, and for each source which bars show and
# what they are drawn with. Nothing changes until Save.
function Show-Settings {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'token-hungry settings'
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.AutoSize = $true; $form.AutoSizeMode = 'GrowAndShrink'; $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true; $form.Padding = New-Object Windows.Forms.Padding 10
    $form.Font = New-Object Drawing.Font $monocraft, 9
    $tips = New-Object Windows.Forms.ToolTip
    $flags, $choices = @{}, @{}

    function New-Flow($direction) {
        $flow = New-Object Windows.Forms.FlowLayoutPanel
        $flow.FlowDirection = $direction; $flow.AutoSize = $true; $flow.WrapContents = $false
        $flow
    }
    function Add-Check($parent, $text, $setting, [switch]$Inverted) {
        $box = New-Object Windows.Forms.CheckBox
        $box.Text = $text; $box.Width = 130; $box.Checked = (Test-On $setting) -ne [bool]$Inverted
        $box.Anchor = 'Left'
        $flags[$setting] = @($box, [bool]$Inverted)
        $parent.Controls.Add($box)
    }
    function Add-Pick($parent, $setting, $options, $current, $scale) {  # options: value -> sprite name
        $grid = New-Flow LeftToRight
        $grid.WrapContents = $true
        $parent.Controls.Add($grid)
        $parent = $grid
        $buttons = foreach ($value in $options.Keys) {
            $button = New-Object Windows.Forms.RadioButton
            $button.Appearance = 'Button'; $button.Tag = $value; $button.Checked = $value -eq $current
            $button.FlatStyle = 'Flat'; $button.FlatAppearance.CheckedBackColor = [Drawing.Color]::LightSkyBlue
            $button.FlatAppearance.BorderColor = [Drawing.Color]::Silver
            $button.Image = Resize-Picture (Get-Sprite $options[$value]) ($scale * $menuScale)
            $button.Size = New-Object Drawing.Size ($button.Image.Width + 10), ($button.Image.Height + 10)
            $button.Margin = New-Object Windows.Forms.Padding 1
            $tips.SetToolTip($button, ($value -replace '_', ' '))
            $parent.Controls.Add($button)
            $button
        }
        $grid.MaximumSize = New-Object Drawing.Size (12 * ($buttons[0].Width + 2)), 0  # twelve to a line
        $choices[$setting] = @($buttons, $current)
    }

    $layout = New-Flow TopDown
    $switches = New-Flow LeftToRight
    foreach ($switch in 'minecraft', 'wide', 'stacked') { Add-Check $switches ((Get-Culture).TextInfo.ToTitleCase($switch)) $switch }
    $layout.Controls.Add($switches)
    foreach ($source in $sources) {
        $name = $source.Name
        $group = New-Object Windows.Forms.GroupBox
        $group.Text = $name; $group.AutoSize = $true; $group.Padding = New-Object Windows.Forms.Padding 6
        $rows = New-Flow TopDown
        $rows.Dock = 'Fill'
        $labels = if ($providers.Contains($name)) { , 'Balance' } else { 'Session', 'Weekly', 'Resets' }
        foreach ($label in $labels) {
            $row = New-Flow LeftToRight
            Add-Check $row "Show $label" (Get-Key hide $name $label) -Inverted
            if ($label -eq 'Balance') {
                $options = [ordered]@{}; foreach ($currency in $currencies) { $options[$currency] = $currency }
                Add-Pick $row (Get-Key icon $name) $options (Get-Currency $name) 1
            } elseif ($label -ne 'Resets') {
                $options = [ordered]@{}; foreach ($style in $bars.Keys) { $options[$style] = $bars[$style][2] }
                Add-Pick $row (Get-Key bar $name $label) $options (Get-Bar $name $label) 2
            }
            $rows.Controls.Add($row)
        }
        $group.Controls.Add($rows)
        $layout.Controls.Add($group)
    }

    # A key typed here is kept in the user's environment; an empty box keeps
    # the key there is.
    $keys = @{}
    $group = New-Object Windows.Forms.GroupBox
    $group.Text = 'API keys'; $group.AutoSize = $true; $group.Padding = New-Object Windows.Forms.Padding 6
    $rows = New-Flow TopDown
    $rows.Dock = 'Fill'
    $hint = New-Object Windows.Forms.Label
    $hint.AutoSize = $true; $hint.MaximumSize = New-Object Drawing.Size 420, 0
    $hint.Text = 'Paste a key to show that balance. Claude and ChatGPT show up by themselves when Claude Code or Codex is signed in on this PC.'
    $rows.Controls.Add($hint)
    foreach ($name in $providers.Keys) {
        $row = New-Flow LeftToRight
        $label = New-Object Windows.Forms.Label
        $label.Text = $name; $label.Width = 110; $label.Anchor = 'Left'; $label.TextAlign = 'MiddleLeft'
        $box = New-Object Windows.Forms.TextBox
        $box.Width = 230; $box.UseSystemPasswordChar = $true
        $state = New-Object Windows.Forms.Label
        $state.AutoSize = $true; $state.Anchor = 'Left'
        $state.Text = if (Get-ApiKey $providers[$name].Key) { 'saved' } else { 'not set' }
        $link = New-Object Windows.Forms.LinkLabel
        $link.Text = 'Get a key'; $link.AutoSize = $true; $link.Anchor = 'Left'; $link.Tag = $providers[$name].KeyPage
        $link.Add_LinkClicked({ param($from) Start-Process $from.Tag })
        $row.Controls.AddRange(@($label, $box, $state, $link))
        $rows.Controls.Add($row)
        $keys[$providers[$name].Key] = $box
    }
    $group.Controls.Add($rows)
    $layout.Controls.Add($group)

    $buttons = New-Flow RightToLeft
    $buttons.Anchor = 'Right'
    foreach ($text in 'Cancel', 'Save') {
        $button = New-Object Windows.Forms.Button
        $button.Text = $text
        $button.DialogResult = if ($text -eq 'Save') { 'OK' } else { 'Cancel' }
        $buttons.Controls.Add($button)
        if ($text -eq 'Save') { $form.AcceptButton = $button } else { $form.CancelButton = $button }
    }
    $layout.Controls.Add($buttons)
    $form.Controls.Add($layout)

    if ($form.ShowDialog() -ne 'OK') { return }
    foreach ($setting in $flags.Keys) {
        $box, $inverted = $flags[$setting]
        $path = Join-Path $here ".$setting"
        if ($box.Checked -ne $inverted) { [IO.File]::WriteAllText($path, '') } else { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
    foreach ($setting in $choices.Keys) {
        $buttons, $current = $choices[$setting]
        $chosen = ($buttons | Where-Object { $_.Checked } | Select-Object -First 1).Tag
        if ($chosen -and $chosen -ne $current) { [IO.File]::WriteAllText((Join-Path $here ".$setting"), $chosen) }
    }
    $typed = @($keys.Keys | Where-Object { $keys[$_].Text.Trim() })
    foreach ($key in $typed) { Set-ApiKey $key $keys[$key].Text.Trim() }
    if ($typed) { Update-All } else { Show-All }  # a new key brings a new source to fetch
}

# Lays the titles out side by side, each a picture and then its text, and
# remembers where each one sits so a click can find it.
function Paint {
    $tray = [Strip]::Tray()
    $height = $tray.Bottom - $tray.Top
    $measure = [Drawing.Graphics]::FromImage((New-Object Drawing.Bitmap 1, 1))
    $font = New-Object Drawing.Font 'Segoe UI', 9
    $x = 6
    foreach ($source in $sources) {
        $source.Left = $x
        if ($source.Image) { $x += $source.Image.Width + $(if ($source.Text) { 4 } else { 0 }) }
        if ($source.Text) { $x += [int][Math]::Ceiling($measure.MeasureString($source.Text, $font).Width) }
        $source.Right = $x
        $x += 14
    }
    $bitmap = New-Object Drawing.Bitmap ([Math]::Max(1, $x - 8)), $height, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([Drawing.Color]::FromArgb(1, 0, 0, 0))  # nearly clear, so the whole strip takes clicks
    $graphics.TextRenderingHint = 'AntiAliasGridFit'
    foreach ($source in $sources) {
        $x = $source.Left
        if ($source.Image) {
            $graphics.DrawImage($source.Image, $x, [int](($height - $source.Image.Height) / 2), $source.Image.Width, $source.Image.Height)
            $x += $source.Image.Width + 4
        }
        if ($source.Text) {
            $y = ($height - $measure.MeasureString($source.Text, $font).Height) / 2
            $graphics.DrawString($source.Text, $font, (New-Object Drawing.SolidBrush $source.Color), $x, $y)
        }
    }
    $script:frame = $bitmap
    Place -Force
}

# Draws the strip where the tray is, again only when the frame or the tray
# moved, and puts it back on top, which a click on the taskbar takes away.
function Place([switch]$Force) {
    $tray = [Strip]::Tray()
    $at = "$($tray.Left),$($tray.Top),$($script:frame.Width)"
    if ($Force -or $at -ne $script:placed) {
        $strip.Draw($script:frame, $tray.Left - $script:frame.Width - 4, $tray.Top)
        $script:placed = $at
    }
    $strip.KeepOnTop()
}

# Redraws from what the sources last said, after a setting changed.
function Show-All {
    foreach ($source in $sources) { Show-Source $source }
    Paint
    $animate.Start()  # stops itself when nothing moves
}

# Animations, in ticks of the animation timer (100 ms), as in the game: a bar
# that lost icons since the last refresh blinks, one that got icons back runs
# the regeneration wave, and one nearly empty shakes until it fills again.
function Watch-Rows($source) {
    if ($null -eq $source.Effects) { $source.Effects = @{}; $source.Pcts = @{} }
    foreach ($row in $source.Model.Rows) {
        $was = $source.Pcts[$row.Label]
        if ($null -ne $was) {
            $before, $now = (Get-Halves $was), (Get-Halves $row.Pct)
            if ($now -lt $before) { $source.Effects[$row.Label] = @{ Kind = 'blink'; Start = $script:tick } }
            if ($now -gt $before) { $source.Effects[$row.Label] = @{ Kind = 'wave'; Start = $script:tick } }
        }
        $source.Pcts[$row.Label] = $row.Pct
    }
}

function Get-Looks($source) {
    $looks = @{}
    $icons = Get-Icons
    foreach ($row in $source.Model.Rows) {
        $effect = if ($source.Effects) { $source.Effects[$row.Label] }
        $t = if ($effect) { $script:tick - $effect.Start } else { 0 }
        if ($effect -and (($effect.Kind -eq 'blink' -and $t -ge 8) -or ($effect.Kind -eq 'wave' -and $t -gt $icons))) {
            $source.Effects.Remove($row.Label); $effect = $null
        }
        $halves = Get-Halves $row.Pct
        if ($effect.Kind -eq 'blink') {
            $looks[$row.Label] = @{ Blink = $t % 2 -eq 0 }  # four flashes
        } elseif ($effect.Kind -eq 'wave') {
            $looks[$row.Label] = @{ Lift = @(0..($icons - 1) | ForEach-Object { if ($_ -eq $t) { 2 } elseif ([Math]::Abs($_ - $t) -eq 1) { 1 } else { 0 } }) }
        } elseif ($halves -le 2 * $icons / 5) {  # a fifth or less left, like four health points of twenty
            $random = New-Object Random ([int][Math]::Floor($script:tick / 3) * 31 + [int]$row.Label[0])  # new shake every 300 ms
            $looks[$row.Label] = @{ Lift = @(1..$icons | ForEach-Object { $random.Next(2) }) }
        }
    }
    $looks
}

# One tick: redraws the titles whose look changed, and stops when none moves.
function Step-Animation {
    $script:tick++
    $busy = $changed = $false
    if (Test-On minecraft) {
        foreach ($source in $sources) {
            if ($source.Model.Error -or -not $source.Model.Rows) { continue }
            $looks = Get-Looks $source
            if ($looks.Count) { $busy = $true }
            $key = $looks | ConvertTo-Json -Compress -Depth 3
            if ($key -ne $source.LookKey) {
                if (-not $source.Frames[$key]) { $source.Frames[$key] = New-MinecraftTitle $source.Name $source.Model $looks }
                if ($source.Frames[$key]) { $source.Image = $source.Frames[$key]; $changed = $true }
                $source.LookKey = $key
            }
        }
    }
    if ($changed) { Paint }
    if (-not $busy) { $animate.Stop() }
}

# Asks every source again. The list itself is made again too, so a key set or
# a login made since the last refresh shows up.
function Update-All {
    $known = @{}; foreach ($source in $script:sources) { $known[$source.Name] = $source }
    $script:sources = @(Get-Sources $names | ForEach-Object {
        if ($known[$_.Name]) { $known[$_.Name] } else { $_.Menu = New-Object Windows.Forms.ContextMenuStrip; $_ }
    })
    foreach ($source in $sources) { Update-Model $source; Watch-Rows $source }
    Show-All
}

$names = $args
$sources = @()
$tick = 0
$animate = New-Object Windows.Forms.Timer
$animate.Interval = 100
$animate.Add_Tick({ Step-Animation })
$strip = New-Object Strip
$strip.Add_MouseUp({
    param($from, $click)
    $source = $sources | Where-Object { $click.X -ge $_.Left -and $click.X -lt $_.Right + 7 } | Select-Object -First 1
    if ($source) {
        [void][Strip]::SetForegroundWindow($strip.Handle)  # so the menu closes on a click elsewhere
        $source.Menu.Show($strip, (New-Object Drawing.Point $source.Left, 0), 'AboveRight')
    }
})
$strip.Show()
Update-All
# The first start asks for keys, and so does a start with nothing to show,
# since there is then no title to click.
if (-not (Test-On welcomed) -or -not $sources) {
    [IO.File]::WriteAllText((Join-Path $here '.welcomed'), '')
    Show-Settings
}

$refresh = New-Object Windows.Forms.Timer
$refresh.Interval = 5 * 60 * 1000
$refresh.Add_Tick({ Update-All })
$refresh.Start()
# Stays above the taskbar as soon as it comes forward, and follows the tray
# as it grows or shrinks.
$strip.FollowTaskbar()
$follow = New-Object Windows.Forms.Timer
$follow.Interval = 1000
$follow.Add_Tick({ Place })
$follow.Start()
[Windows.Forms.Application]::Run()
