variable "docker_host" {
  description = "Docker host connection string (e.g. unix:///var/run/docker.sock). Leave empty to use the local default."
  type        = string
  default     = ""
}

variable "build_context" {
  description = "Path to the Docker build context. Defaults to the repository root."
  type        = string
  default     = ""
}

variable "dockerfile" {
  description = "Path to the Dockerfile used for building the image. Defaults to the repository Dockerfile."
  type        = string
  default     = ""
}

variable "build_target" {
  description = "Optional Docker build target."
  type        = string
  default     = ""
}

variable "build_args" {
  description = "Additional Docker build arguments."
  type        = map(string)
  default     = {}
}

variable "pull_triggers" {
  description = "List of values that force the image to rebuild when they change."
  type        = list(string)
  default     = []
}

variable "keep_image_locally" {
  description = "Whether to keep the built image on the local machine."
  type        = bool
  default     = true
}

variable "force_remove" {
  description = "Remove the image from Docker when Terraform destroys it."
  type        = bool
  default     = true
}

variable "remove_intermediate_images" {
  description = "Remove intermediate containers after a successful build."
  type        = bool
  default     = true
}

variable "image_name" {
  description = "Name of the Docker image to build."
  type        = string
  default     = "maestro-orchestrator"
}

variable "image_tag" {
  description = "Tag applied to the built image."
  type        = string
  default     = "iac"
}

variable "container_name" {
  description = "Name of the managed container."
  type        = string
  default     = "maestro-orchestrator"
}

variable "restart_policy" {
  description = "Docker restart policy for the container."
  type        = string
  default     = "unless-stopped"
}

variable "must_run" {
  description = "Whether the container must be running (Terraform will recreate it if it stops)."
  type        = bool
  default     = true
}

variable "privileged" {
  description = "Run the container in privileged mode."
  type        = bool
  default     = false
}

variable "working_dir" {
  description = "Working directory inside the container."
  type        = string
  default     = ""
}

variable "wait" {
  description = "Wait for the container to be in a healthy state before completing."
  type        = bool
  default     = false
}

variable "wait_timeout" {
  description = "Timeout (in seconds) for container health checks when wait is true."
  type        = number
  default     = 60
}

variable "remove_volumes" {
  description = "Remove anonymous volumes on container destroy."
  type        = bool
  default     = false
}

variable "command" {
  description = "Override command passed to the container."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Additional labels to apply to the container."
  type        = map(string)
  default     = {}
}

variable "mounts" {
  description = "List of mounts to attach to the container."
  type = list(object({
    target    = string
    source    = string
    type      = optional(string, "bind")
    read_only = optional(bool, false)
  }))
  default = []
}

variable "ports" {
  description = "Port mappings between the container and the host."
  type = list(object({
    internal = number
    external = number
    protocol = optional(string, "tcp")
  }))
  default = []
}

variable "networks" {
  description = "Advanced Docker network attachments."
  type = list(object({
    name         = string
    aliases      = optional(list(string))
    ipv4_address = optional(string)
    ipv6_address = optional(string)
  }))
  default = []
}

variable "container_env" {
  description = "Additional environment variables passed to the container."
  type        = map(string)
  default     = {}
}
