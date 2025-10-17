terraform {
  required_version = ">= 1.4.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {
  host = var.docker_host != "" ? var.docker_host : null
}

locals {
  project_root = abspath("${path.module}/../..")

  build_context = var.build_context != "" ? var.build_context : local.project_root
  dockerfile    = var.dockerfile != "" ? var.dockerfile : "${local.project_root}/Dockerfile"

  build_args = {
    for key, value in var.build_args :
    key => value
    if try(trim(value), "") != ""
  }

  runtime_env = {
    for key, value in var.container_env :
    key => value
    if try(trim(value), "") != ""
  }

  port_mappings = [
    for mapping in var.ports : {
      internal = mapping.internal
      external = mapping.external
      protocol = try(mapping.protocol, "tcp")
    }
  ]
}

resource "docker_image" "maestro" {
  name          = "${var.image_name}:${var.image_tag}"
  keep_locally  = var.keep_image_locally
  force_remove  = var.force_remove
  pull_triggers = var.pull_triggers

  build {
    context     = local.build_context
    dockerfile  = local.dockerfile
    build_args  = local.build_args
    target      = var.build_target != "" ? var.build_target : null
    remove      = var.remove_intermediate_images
  }

  lifecycle {
    ignore_changes = [
      pull_triggers,
    ]
  }
}

resource "docker_container" "maestro" {
  name       = var.container_name
  image      = docker_image.maestro.image_id
  restart    = var.restart_policy
  must_run   = var.must_run
  privileged = var.privileged
  working_dir = var.working_dir != "" ? var.working_dir : null
  wait         = var.wait
  wait_timeout = var.wait_timeout
  remove_volumes = var.remove_volumes

  env = [
    for key, value in local.runtime_env : "${key}=${value}"
  ]

  command = var.command

  labels = merge(
    {
      "managed-by" = "terraform"
    },
    var.labels
  )

  dynamic "ports" {
    for_each = local.port_mappings
    content {
      internal = ports.value.internal
      external = ports.value.external
      protocol = ports.value.protocol
    }
  }

  dynamic "mounts" {
    for_each = var.mounts
    content {
      target    = mounts.value.target
      source    = mounts.value.source
      type      = try(mounts.value.type, "bind")
      read_only = try(mounts.value.read_only, false)
    }
  }

  dynamic "networks_advanced" {
    for_each = var.networks
    content {
      name         = networks_advanced.value.name
      aliases      = try(networks_advanced.value.aliases, null)
      ipv4_address = try(networks_advanced.value.ipv4_address, null)
      ipv6_address = try(networks_advanced.value.ipv6_address, null)
    }
  }

  depends_on = [
    docker_image.maestro
  ]
}
