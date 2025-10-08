output "image_id" {
  description = "ID of the Docker image built for Maestro."
  value       = docker_image.maestro.image_id
}

output "container_name" {
  description = "Name of the running Maestro container."
  value       = docker_container.maestro.name
}

output "container_id" {
  description = "Docker ID of the running Maestro container."
  value       = docker_container.maestro.id
}

output "published_ports" {
  description = "Published host ports for the Maestro container."
  value = [
    for mapping in docker_container.maestro.ports : {
      internal = mapping.internal
      external = mapping.external
      protocol = mapping.protocol
    }
  ]
}
