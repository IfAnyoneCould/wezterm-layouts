# saves a wezterm window and opens it back up. splits come from the pane
# geometry in wezterm cli list, nvim tabs come from a session file each nvim
# writes when asked over its pipe
param(
  [Parameter(Position = 0)] [string] $Cmd,
  [Parameter(Position = 1)] [string] $Name,
  [switch] $Window
)
$ErrorActionPreference = 'Stop'

$root = $env:WZL_DIR ?? "$HOME\.config\wezterm\layouts"
# WEZTERM_EXECUTABLE is wezterm-gui, the cli lives next to it
$wez = if ($env:WEZTERM_EXECUTABLE) { Join-Path (Split-Path $env:WEZTERM_EXECUTABLE) 'wezterm.exe' } else { 'wezterm' }

function Wez {
  $out = & $wez cli @args
  if ($LASTEXITCODE) { throw "wezterm cli $args failed" }
  $out
}

function Get-Panes { Wez list --format json | ConvertFrom-Json }

function Nvim-Expr($server, $expr) { nvim --headless --server $server --remote-expr $expr 2>$null }

# every nvim started from a pane inherits that pane's WEZTERM_PANE
function Get-Nvims {
  $map = @{}
  foreach ($s in [IO.Directory]::GetFiles('\\.\pipe\') -like '*nvim*') {
    $id = Nvim-Expr $s '$WEZTERM_PANE'
    if ($id) { $map["$id"] = $s }
  }
  $map
}

# C:\x -> /mnt/c/x, \\wsl.localhost\distro\x -> /x
function To-Wsl($path) {
  if ($path -match '^\\\\wsl(\.localhost|\$)\\[^\\]+(.*)') { return $Matches[2].Replace('\', '/') }
  '/mnt/' + $path.Substring(0, 1).ToLower() + $path.Substring(2).Replace('\', '/')
}

# windows cant see a wsl pane's cwd or nvims, so the probe in ./wzl runs in
# each distro and finds them by WEZTERM_PANE
function Get-WslPanes($dir) {
  $map = @{}
  if (-not (Get-Command wsl.exe -ErrorAction Ignore)) { return $map }
  $env:WSL_UTF8 = 1
  $distros = wsl.exe -l --running -q | ? { $_ -and $_ -notlike 'docker-desktop*' }
  # the probe would count itself as a shell in this pane otherwise
  $keep = $env:WSLENV; $env:WSLENV = ''
  try {
    foreach ($d in $distros) {
      foreach ($line in wsl.exe -d $d -e bash (To-Wsl "$PSScriptRoot\wzl") _probe (To-Wsl $dir)) {
        $kind, $pane, $cwd = $line -split "`t", 3
        if (-not $map[$pane]) { $map[$pane] = @{ distro = $d } }
        $map[$pane].cwd = $cwd
        if ($kind -eq 'nvim') { $map[$pane].nvim = "nvim-$pane.vim" }
      }
    }
  } finally { $env:WSLENV = $keep }
  $map
}

function Save {
  if (-not $env:WEZTERM_PANE) { throw 'has to be run inside wezterm' }
  if ($Name -notmatch '^[\w.-]+$') { throw "bad name '$Name', stick to letters, numbers, . - _" }
  $panes = Get-Panes
  $here = $panes | ? pane_id -eq $env:WEZTERM_PANE

  # a zoomed pane hides the real splits, so unzoom to read them then zoom back
  $zoomed = @($panes | ? { $_.window_id -eq $here.window_id -and $_.is_zoomed })
  foreach ($p in $zoomed) { Wez zoom-pane --pane-id $p.pane_id --unzoom | Out-Null }
  if ($zoomed) { $panes = Get-Panes }
  foreach ($p in $zoomed) { Wez zoom-pane --pane-id $p.pane_id --zoom | Out-Null }

  $dir = Join-Path $root $Name
  $existed = Test-Path $dir
  if ($existed) { Remove-Item $dir -Recurse -Force }
  New-Item -ItemType Directory $dir -Force | Out-Null

  $nvims = Get-Nvims
  $wsl = Get-WslPanes $dir
  $tabs = [ordered]@{}
  foreach ($p in $panes | ? window_id -eq $here.window_id) {
    if (-not $tabs.Contains($p.tab_id)) {
      $tabs[$p.tab_id] = [ordered]@{ title = $p.tab_title; active = $p.tab_id -eq $here.tab_id; panes = @() }
    }
    # pwsh cd doesnt move the process so wezterm's cwd goes stale without osc7
    $cwd = if ($p.pane_id -eq $here.pane_id) { $PWD.Path } elseif ($p.cwd) { ([uri]$p.cwd).LocalPath }
    $vim = $null
    if ($s = $nvims["$($p.pane_id)"]) {
      $vim = "nvim-$($p.pane_id).vim"
      $f = (Join-Path $dir $vim).Replace('\', '/')
      Nvim-Expr $s "execute('mksession! ' .. fnameescape('$f'))" | Out-Null
      $cwd = Nvim-Expr $s 'getcwd()'
    }
    if ($w = $wsl["$($p.pane_id)"]) { $cwd = $w.cwd; $vim = $w.nvim }
    $tabs[$p.tab_id].panes += [ordered]@{
      left = $p.left_col; top = $p.top_row; cols = $p.size.cols; rows = $p.size.rows
      cwd = $cwd; nvim = $vim; wsl = $w.distro; active = $p.is_active; zoomed = $p.pane_id -in $zoomed.pane_id
    }
  }

  @{ saved = (Get-Date).ToString('yyyy-MM-dd HH:mm'); tabs = @($tabs.Values) } |
    ConvertTo-Json -Depth 6 | Set-Content "$dir\layout.json"
  $n = @($tabs.Values.panes).Count
  $v = @($tabs.Values.panes | ? { $_.nvim }).Count
  "$(($existed) ? 'updated' : 'saved') $Name, $($tabs.Count) tabs $n panes $v nvim"
}

# finds the line wezterm split along, every pane has to sit fully on one side
function Get-Tree($panes) {
  if ($panes.Count -eq 1) { return @{ pane = $panes[0] } }
  foreach ($ax in @('left', 'cols', '--right'), @('top', 'rows', '--bottom')) {
    $at, $len, $side = $ax
    $start = ($panes.$at | measure -Minimum).Minimum
    $end = ($panes | % { $_.$at + $_.$len } | measure -Maximum).Maximum
    foreach ($c in $panes.$at | sort -Unique | ? { $_ -gt $start }) {
      $a = @($panes | ? { $_.$at + $_.$len -lt $c })
      $b = @($panes | ? { $_.$at -ge $c })
      if ($a.Count + $b.Count -ne $panes.Count) { continue }
      $pct = [math]::Clamp([math]::Round(100 * ($end - $c) / ($end - $start)), 1, 99)
      return @{ side = $side; pct = $pct; a = Get-Tree $a; b = Get-Tree $b }
    }
  }
  throw 'couldnt work out how the panes were split'
}

# the pane that ends up keeping the id when a region gets split
function First($t) { if ($t.pane) { $t.pane } else { First $t.a } }

function Spawn-Args($p) {
  if ($p.wsl) {
    # straight into wsl, WEZTERM_PANE already gets through from the WSLENV in .wezterm.lua
    $a = '--', 'wsl', '-d', $p.wsl, '--cd', $p.cwd
    if ($p.nvim) { $a += '-e', 'zsh', '-ic', "nvim -S '$(To-Wsl (Join-Path $dir $p.nvim))'; exec zsh" }
    return $a
  }
  $a = @()
  if ($p.cwd -and (Test-Path -LiteralPath $p.cwd)) { $a += '--cwd', $p.cwd }
  if ($p.nvim) { $a += '--', "$HOME\scoop\apps\msys2\current\usr\bin\zsh.exe", '-lic', "nvim -S '$(Join-Path $dir $p.nvim)'; exec zsh -l" }
  $a
}

function Restore($t, $id) {
  if ($t.pane) {
    if ($t.pane.active) { $script:focus = $id }
    if ($t.pane.zoomed) { $script:zoom += $id }
    return
  }
  $new = Wez split-pane --pane-id $id $t.side --percent $t.pct @(Spawn-Args (First $t.b))
  Restore $t.a $id
  Restore $t.b $new
}

function Open {
  $dir = Join-Path $root $Name
  if (-not (Test-Path "$dir\layout.json")) { throw "nothing saved as $Name" }
  $layout = Get-Content "$dir\layout.json" -Raw | ConvertFrom-Json
  $panes = if ($env:WEZTERM_PANE) { Get-Panes }
  $here = $panes | ? pane_id -eq $env:WEZTERM_PANE
  $win = if ($here -and -not $Window) { $here.window_id }

  $script:zoom = @()
  $last = $null
  foreach ($t in $layout.tabs) {
    $tree = Get-Tree @($t.panes)
    $to = @(if ($null -ne $win) { '--window-id', $win } else { '--new-window' })
    $id = Wez spawn @to @(Spawn-Args (First $tree))
    if ($null -eq $win) { $win = (Get-Panes | ? pane_id -eq $id).window_id }
    $script:focus = $id
    Restore $tree $id
    if ($t.title) { Wez set-tab-title --pane-id $id $t.title | Out-Null }
    if ($t.active) { $last = $script:focus } else { Wez activate-pane --pane-id $script:focus | Out-Null }
  }
  foreach ($id in $script:zoom) { Wez zoom-pane --pane-id $id --zoom | Out-Null }
  if ($last) { Wez activate-pane --pane-id $last | Out-Null }

  # the shell this ran from is just in the way unless it shares its tab
  if ($here -and -not $Window -and @($panes | ? tab_id -eq $here.tab_id).Count -eq 1) {
    Wez kill-pane --pane-id $here.pane_id
  }
}

function Get-Layouts {
  Get-ChildItem $root -Directory -ErrorAction Ignore | ? { Test-Path "$($_.FullName)\layout.json" } | % {
    $l = Get-Content "$($_.FullName)\layout.json" -Raw | ConvertFrom-Json
    $p = @($l.tabs.panes)
    '{0,-20} {1} tabs  {2} panes  {3} nvim  {4}' -f $_.Name, @($l.tabs).Count, $p.Count, @($p | ? nvim).Count, $l.saved
  }
}

# arrow key menu like claude code's, returns the index or $null on esc
function Menu($title, $items) {
  $i = 0
  Write-Host "`n $title`n"
  [Console]::CursorVisible = $false
  try {
    while ($true) {
      for ($n = 0; $n -lt $items.Count; $n++) {
        $line = '{0}. {1}' -f ($n + 1), $items[$n]
        if ($n -eq $i) { Write-Host "`e[2K `e[36m❯ $line`e[0m" } else { Write-Host "`e[2K   $line" }
      }
      Write-Host "`e[2K`e[90m   ↑/↓ move  enter pick  esc cancel`e[0m" -NoNewline
      $k = [Console]::ReadKey($true)
      $pick = $null
      if ($k.Key -eq 'UpArrow' -or $k.KeyChar -eq 'k') { $i = ($i - 1 + $items.Count) % $items.Count }
      elseif ($k.Key -eq 'DownArrow' -or $k.KeyChar -eq 'j') { $i = ($i + 1) % $items.Count }
      elseif ($k.Key -eq 'Enter') { $pick = $i }
      elseif ($k.KeyChar -match '\d' -and [int]"$($k.KeyChar)" -ge 1 -and [int]"$($k.KeyChar)" -le $items.Count) { $pick = [int]"$($k.KeyChar)" - 1 }
      elseif ($k.Key -eq 'Escape' -or $k.KeyChar -eq 'q') { $pick = -1 }
      # back up to the first item and redraw over it
      Write-Host "`r`e[$($items.Count)A" -NoNewline
      if ($null -ne $pick) {
        Write-Host "`e[0J" -NoNewline
        if ($pick -lt 0) { Write-Host '   cancelled'; return $null }
        Write-Host " `e[36m❯ $($items[$pick])`e[0m"
        return $pick
      }
    }
  } finally { [Console]::CursorVisible = $true }
}

function Pick($title) {
  $rows = @(Get-Layouts)
  if (-not $rows) { throw 'nothing saved yet' }
  $n = Menu $title $rows
  if ($null -eq $n) { exit }
  ($rows[$n] -split ' ')[0]
}

function Confirm($title) { (Menu $title 'No', 'Yes') -eq 1 }

function Remove {
  $dir = Join-Path $root $Name
  if (-not (Test-Path $dir)) { throw "nothing saved as $Name" }
  if (-not (Confirm "remove ${Name}?")) { exit }
  Remove-Item $dir -Recurse -Force
  "removed $Name"
}

switch ($Cmd) {
  'save' { if (-not $Name) { $Name = Split-Path $PWD -Leaf }; Save }
  'ls' { Get-Layouts }
  'rm' { if (-not $Name) { $Name = Pick 'which one?' }; Remove }
  'open' { if (-not $Name) { $Name = Pick 'which one?' }; Open }
  { $_ -in 'help', '-h', '--help' } {
    'wzl                 menu'
    'wzl <name>          open it'
    'wzl save [name]     save this window, name defaults to the folder'
    'wzl ls              list layouts'
    'wzl rm [name]       remove one'
    '-Window             open into a new window instead of this one'
  }
  '' {
    $n = Menu 'wezterm layouts' 'Open a layout', 'Save this window', 'Remove a layout'
    if ($null -eq $n) { exit }
    if ($n -eq 1) {
      $def = Split-Path $PWD -Leaf
      $Name = (Read-Host "`n name ($def)").Trim()
      if (-not $Name) { $Name = $def }
      if ((Test-Path (Join-Path $root $Name)) -and -not (Confirm "${Name} already exists, overwrite?")) { exit }
      Save
    } else {
      $Name = Pick 'which one?'
      if ($n -eq 0) { Open } else { Remove }
    }
  }
  default { $Name = $Cmd; Open }
}
