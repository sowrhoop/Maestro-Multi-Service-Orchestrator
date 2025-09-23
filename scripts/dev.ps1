Param(
  [int] $APort = 8080,
  [int] $BPort = 9090
)

Write-Host "Starting local dev servers..."

# Python venv
if (-not (Test-Path .venv)) {
  python -m venv .venv | Out-Null
}
& .\.venv\Scripts\pip.exe install --disable-pip-version-check -q -r services\service-a\requirements.txt | Out-Null

$env:PORT = "$APort"
$jobA = Start-Job -ScriptBlock {
  param($port)
  $env:PORT = "$port"
  & $using:PWD\.venv\Scripts\python.exe services/service-a/app.py
} -ArgumentList $APort

Set-Location services\service-b
if (Test-Path package-lock.json) {
  npm ci --silent | Out-Null
} else {
  npm install --no-audit --no-fund --silent | Out-Null
}
$env:PORT = "$BPort"
$env:SERVICE_A_URL = "http://127.0.0.1:$APort"
$jobB = Start-Job -ScriptBlock {
  param($port)
  $env:PORT = "$port"
  $env:SERVICE_A_URL = $env:SERVICE_A_URL
  node server.js
} -ArgumentList $BPort
Set-Location ../..

Write-Host "Service A: http://localhost:$APort/"
Write-Host "Service B: http://localhost:$BPort/ (UI)"
Write-Host "Use 'Get-Job' to see jobs and 'Stop-Job -Id <id>' to stop."

