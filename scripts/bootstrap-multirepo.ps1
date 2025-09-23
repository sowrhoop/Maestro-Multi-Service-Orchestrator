Param(
  [Parameter(Mandatory=$true)] [string] $Owner,
  [ValidateSet('public','private')] [string] $Visibility = 'public'
)

function Require-Cli($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Error "Required CLI not found: $name"; exit 1
  }
}

Require-Cli gh

$tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath()) -Name ("bootstrap-" + [System.Guid]::NewGuid())

function Bootstrap($repoName, $src) {
  $repo = "$Owner/$repoName"
  $dir = Join-Path $tmp $repoName
  New-Item -ItemType Directory -Path $dir | Out-Null
  Copy-Item -Recurse -Force $src/* $dir
  Push-Location $dir
  git init | Out-Null
  git add . | Out-Null
  git commit -m "Initial commit: $repoName" | Out-Null
  gh repo create $repo --$Visibility --source . --push
  Pop-Location
}

Bootstrap 'project-1' 'templates/project-1-python'
Bootstrap 'project-2' 'templates/project-2-node'

Write-Host "Done. Repos created under https://github.com/$Owner"

