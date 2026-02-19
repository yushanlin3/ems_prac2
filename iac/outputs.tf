output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "container_app_fqdn" {
  value = azurerm_container_app.app.latest_revision_fqdn
}

output "app_url" {
  value = "https://${azurerm_container_app.app.latest_revision_fqdn}/hola"
}
