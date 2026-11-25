output "app_url" {
  value = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "container_app_name" {
  value = azurerm_container_app.this.name
}

# Feed back into infra/bootstrap (var.redirect_domain) once, after the first apply.
output "easy_auth_redirect_domain" {
  value = azurerm_container_app_environment.this.default_domain
}

# Settings for the ingest and evaluation scripts (no secrets).
output "local_env" {
  value = {
    AZURE_OPENAI_ENDPOINT         = azurerm_cognitive_account.openai.endpoint
    AZURE_OPENAI_CHAT_DEPLOYMENT  = azurerm_cognitive_deployment.chat.name
    AZURE_OPENAI_EMBED_DEPLOYMENT = azurerm_cognitive_deployment.embedding.name
    AZURE_SEARCH_ENDPOINT         = "https://${azurerm_search_service.this.name}.search.windows.net"
    AZURE_SEARCH_INDEX            = local.index
    GROUP_STAFF_ID                = var.group_staff_id
    GROUP_HR_ID                   = var.group_hr_id
  }
}
