<#
.SYNOPSIS
    Make and test your own win-setup packages on this PC.

.DESCRIPTION
    Run from the repo folder in PowerShell:

      .\pkg.ps1 new <name> -Kind github-release   new package that installs an app from a GitHub release
      .\pkg.ps1 new <name> -Kind git-project      new package that clones a repo and runs its setup
      .\pkg.ps1 new <name> -Kind files            new package that installs files kept in this repo
      .\pkg.ps1 test <name>                       build that package and install it here (Admin window)
      .\pkg.ps1 build                             build every package into .\out (checks they pack)

    After 'new', edit packages\<name>\tools\chocolateyInstall.ps1, run 'test', then commit
    and push. The next win-setup run on any PC installs it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('new', 'test', 'build')][string]$Command,
    [Parameter(Position = 1)][string]$Name,
    [ValidateSet('github-release', 'git-project', 'files')][string]$Kind = 'github-release'
)

$ErrorActionPreference = 'Stop'
$Root      = $PSScriptRoot
$PkgDir    = Join-Path $Root 'packages'
$Helpers   = Join-Path $PkgDir '_shared\winsetup-helpers.ps1'
$OutDir    = Join-Path $Root 'out'
$Community = 'https://community.chocolatey.org/api/v2/'

function Assert-Choco {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { throw 'Chocolatey is not installed. Run win-setup first.' }
}

function Build-One([string]$Folder) {
    $nuspec = Get-ChildItem -Path $Folder -Filter '*.nuspec' | Select-Object -First 1
    if (-not $nuspec) { throw "No .nuspec in $Folder" }
    $tools = Join-Path $Folder 'tools'
    if (Test-Path $tools) { Copy-Item -Path $Helpers -Destination $tools -Force }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    & choco pack $nuspec.FullName --out="$OutDir" --limit-output | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "choco pack failed for $($nuspec.Name)" }
    return [string]([xml](Get-Content -Path $nuspec.FullName -Raw)).package.metadata.id
}

switch ($Command) {
    'new' {
        if ($Name -notmatch '^[a-z0-9][a-z0-9.-]*$') { throw "Give a name: lowercase letters, digits, dots, dashes. e.g. .\pkg.ps1 new my-tool -Kind $Kind" }
        $dest = Join-Path $PkgDir $Name
        if (Test-Path $dest) { throw "packages\$Name already exists." }
        Copy-Item -Path (Join-Path $PkgDir "_templates\$Kind") -Destination $dest -Recurse
        Rename-Item -Path (Join-Path $dest 'template.nuspec') -NewName "$Name.nuspec"
        foreach ($f in Get-ChildItem -Path $dest -Recurse -File -Include '*.nuspec', '*.ps1') {
            $text = [IO.File]::ReadAllText($f.FullName)
            [IO.File]::WriteAllText($f.FullName, $text.Replace('__ID__', $Name), (New-Object Text.UTF8Encoding $false))
        }
        Write-Host "Created packages\$Name ($Kind)." -ForegroundColor Green
        Write-Host "Next: edit packages\$Name\tools\chocolateyInstall.ps1, then: .\pkg.ps1 test $Name"
    }
    'test' {
        Assert-Choco
        if (-not $Name) { throw 'Which package? .\pkg.ps1 test <name>' }
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { throw 'Installing needs an Administrator PowerShell window.' }
        $folder = Join-Path $PkgDir $Name
        if (-not (Test-Path $folder)) { throw "No folder packages\$Name" }
        $id = Build-One $folder
        # --force reinstalls even if this version is already installed, so you can iterate.
        & choco install $id -y --force --no-progress --source="$OutDir;$Community"
        if ($LASTEXITCODE -notin 0, 1641, 3010) { throw "Install failed (exit $LASTEXITCODE). Read the output above." }
        Write-Host "$id installed. Commit and push packages\$Name when you are happy." -ForegroundColor Green
    }
    'build' {
        Assert-Choco
        $folders = @(Get-ChildItem -Path $PkgDir -Directory | Where-Object { $_.Name -notlike '_*' })
        if ($folders.Count -eq 0) { Write-Host 'No packages yet. Start with: .\pkg.ps1 new <name>'; return }
        foreach ($f in $folders) { $id = Build-One $f.FullName; Write-Host "  packed $id" -ForegroundColor Green }
        Write-Host "All packed into $OutDir"
    }
}
