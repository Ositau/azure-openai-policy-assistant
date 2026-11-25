output "service_connection" {
  description = "Values for the Azure DevOps service connection (Workload identity federation, manual)."
  value = {
    tenant_id       = data.azurerm_client_config.current.tenant_id
    subscription_id = data.azurerm_client_config.current.subscription_id
    client_id       = azuread_application.pipeline.client_id
  }
}

output "variable_group" {
  description = "Paste into the Azure DevOps variable group `policy-assistant` (none of these are secrets)."
  value = {
    armTenantId       = data.azurerm_client_config.current.tenant_id
    armSubscriptionId = data.azurerm_client_config.current.subscription_id
    armClientId       = azuread_application.pipeline.client_id
    tfStateRg         = azurerm_resource_group.state.name
    tfStateAccount    = azurerm_storage_account.state.name
    tfStateContainer  = azurerm_storage_container.state.name
    appResourceGroup  = azurerm_resource_group.app.name
    keyVaultName      = azurerm_key_vault.app.name
    acrName           = azurerm_container_registry.app.name
    groupStaffId      = azuread_group.demo["staff"].object_id
    groupHrId         = azuread_group.demo["hr"].object_id
    webClientId       = azuread_application.web.client_id
    demoUserObjectId  = data.azurerm_client_config.current.object_id
  }
}
