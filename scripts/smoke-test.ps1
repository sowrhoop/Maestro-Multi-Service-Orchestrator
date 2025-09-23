Param(
  [Parameter(Mandatory=$false)][string] $BaseA = "http://localhost:8080",
  [Parameter(Mandatory=$false)][string] $BaseB = "http://localhost:9090"
)

Write-Host "Checking $BaseA/"
try {
  (Invoke-WebRequest -UseBasicParsing -Uri "$BaseA/").Content | Out-Host
} catch {
  Write-Error "Failed to GET $BaseA/"; exit 1
}

Write-Host "Checking $BaseB/"
try {
  (Invoke-WebRequest -UseBasicParsing -Uri "$BaseB/").Content | Out-Host
} catch {
  Write-Error "Failed to GET $BaseB/"; exit 1
}

Write-Host "Smoke tests passed"
