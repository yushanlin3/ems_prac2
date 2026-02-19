variable "location" {
  type    = string
  default = "westeurope"
}

variable "prefix" {
  type    = string
  default = "ems"
}

variable "suffix" {
  type        = string
  description = "Sufijo único (por ejemplo tu usuario GitHub). Solo minúsculas y números para ACR."
}

variable "environment" {
  type        = string
  description = "staging o production"
}

variable "image_tag" {
  type        = string
  description = "Tag de imagen (por ejemplo SHA corto). Usa 'bootstrap' para despliegue inicial."
  default     = "bootstrap"
}

variable "container_port" {
  type    = number
  default = 8080
}
