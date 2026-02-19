terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  # Backend remoto (recomendado) para que GitHub Actions comparta el estado
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}
