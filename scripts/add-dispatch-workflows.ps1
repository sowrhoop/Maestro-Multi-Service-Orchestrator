Param(
  [Parameter(Mandatory=$true)][string] $Owner,
  [string] $OrchestratorRepo = 'Supervisor-Image-Combination',
  [string] $Branch = 'ci/add-dispatch-merge'
)

function Require-Cli($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    Write-Error "Required CLI not found: $name"; exit 1
  }
}

Require-Cli gh

function Work($Repo) {
  Write-Host "Processing $Owner/$Repo ..."
  $tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath()) -Name ("dispatch-" + [System.Guid]::NewGuid())
  gh repo clone "$Owner/$Repo" $tmp -- --quiet | Out-Null
  Push-Location $tmp
  git checkout -b $Branch | Out-Null
  New-Item -ItemType Directory -Force -Path .github\workflows | Out-Null
  if ($Repo -eq 'project-1') {
    Copy-Item -Force ..\..\templates\dispatch\project-1-dispatch.yml .github\workflows\dispatch-merge.yml
  } else {
    Copy-Item -Force ..\..\templates\dispatch\project-2-dispatch.yml .github\workflows\dispatch-merge.yml
  }
  git add .github/workflows/dispatch-merge.yml | Out-Null
  git commit -m "CI: add dispatch to $OrchestratorRepo merge workflow" | Out-Null
  git push -u origin $Branch | Out-Null
  gh pr create --title "CI: add dispatch to $OrchestratorRepo merge workflow" --body "Adds a workflow that dispatches to $Owner/$OrchestratorRepo after successful builds." | Out-Null
  Pop-Location
}

Work 'project-1'
Work 'project-2'

Write-Host "Done. Ensure secret ORCH_PAT (PAT with 'repo' scope) exists in both repos."

