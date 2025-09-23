Param(
  [Parameter(Mandatory=$false)][string] $DockerUser = $env:DOCKER_USER
)

if (-not $DockerUser) {
  Write-Error "Set -DockerUser or DOCKER_USER env var to your Docker Hub username"
  exit 1
}

Write-Host "Building and pushing $DockerUser/service-a:latest"
docker build -t "$DockerUser/service-a:latest" services/service-a
docker push "$DockerUser/service-a:latest"

Write-Host "Building and pushing $DockerUser/service-b:latest"
docker build -t "$DockerUser/service-b:latest" services/service-b
docker push "$DockerUser/service-b:latest"

Write-Host "Done. Use these images in your Runpod Pod Template."

