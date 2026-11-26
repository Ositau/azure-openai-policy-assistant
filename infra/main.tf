data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix   = random_string.suffix.result
  app_name = "ca-policy-assistant"
  index    = "policies"
}

# Created by infra/bootstrap; the pipeline identity is scoped to this group.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

data "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = var.resource_group_name
}

# ---------- Monitoring (audit trail) ----------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-policy-assistant-${local.suffix}"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.5
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-policy-assistant-${local.suffix}"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = var.tags
}

# ---------- Identity used by the app (no keys anywhere) ----------

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-policy-assistant"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = var.tags
}

# ---------- Azure OpenAI ----------

resource "azurerm_cognitive_account" "openai" {
  name                  = "oai-policy-assistant-${local.suffix}"
  location              = data.azurerm_resource_group.this.location
  resource_group_name   = data.azurerm_resource_group.this.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "oai-policy-assistant-${local.suffix}"
  local_auth_enabled    = true # temporarily, to test with an API key
  tags                  = var.tags
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.chat_model.name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.chat_model.name
    version = var.chat_model.version
  }

  sku {
    name     = var.deployment_sku
    capacity = var.chat_model.capacity
  }
}

resource "azurerm_cognitive_deployment" "embedding" {
  name                 = var.embedding_model.name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.embedding_model.name
    version = var.embedding_model.version
  }

  sku {
    name     = var.deployment_sku
    capacity = var.embedding_model.capacity
  }

  # The service rejects concurrent deployment operations on one account.
  depends_on = [azurerm_cognitive_deployment.chat]
}

# ---------- Azure AI Search (free tier, RBAC only) ----------

resource "azurerm_search_service" "this" {
  name                         = "srch-policy-assistant-${local.suffix}"
  location                     = data.azurerm_resource_group.this.location
  resource_group_name          = data.azurerm_resource_group.this.name
  sku                          = "basic"
  local_authentication_enabled = false
  tags                         = var.tags
}

# ---------- Role assignments ----------

locals {
  app_roles = {
    openai = { scope = azurerm_cognitive_account.openai.id, role = "Cognitive Services OpenAI User" }
    search = { scope = azurerm_search_service.this.id, role = "Search Index Data Reader" }
    acr    = { scope = data.azurerm_container_registry.this.id, role = "AcrPull" }
    kv     = { scope = data.azurerm_key_vault.this.id, role = "Key Vault Secrets User" }
  }

  # Whoever runs ingest/eval: the pipeline identity, plus optionally one person for local runs.
  data_operators = merge(
    { pipeline = data.azurerm_client_config.current.object_id },
    var.demo_user_object_id == "" ? {} : { demo_user = var.demo_user_object_id },
  )
  operator_roles = {
    openai        = { scope = azurerm_cognitive_account.openai.id, role = "Cognitive Services OpenAI User" }
    search_data   = { scope = azurerm_search_service.this.id, role = "Search Index Data Contributor" }
    search_schema = { scope = azurerm_search_service.this.id, role = "Search Service Contributor" }
  }
}

resource "azurerm_role_assignment" "app" {
  for_each             = local.app_roles
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "operators" {
  for_each = {
    for pair in setproduct(keys(local.data_operators), keys(local.operator_roles)) :
    "${pair[0]}-${pair[1]}" => { principal = local.data_operators[pair[0]], role = local.operator_roles[pair[1]] }
  }
  scope                = each.value.role.scope
  role_definition_name = each.value.role.role
  principal_id         = each.value.principal
}

# Role assignments take a short while to apply; wait so the first image pull succeeds.
resource "time_sleep" "rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.app]
}

# ---------- Container Apps ----------

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-policy-assistant"
  location                   = data.azurerm_resource_group.this.location
  resource_group_name        = data.azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = var.tags
}

resource "azurerm_container_app" "this" {
  name                         = local.app_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = data.azurerm_resource_group.this.name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = data.azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  # Easy Auth secret is read from Key Vault by the managed identity; its value
  # never passes through the pipeline or this Terraform state.
  secret {
    name                = "microsoft-provider-authentication-secret"
    key_vault_secret_id = "${data.azurerm_key_vault.this.vault_uri}secrets/easy-auth-client-secret"
    identity            = azurerm_user_assigned_identity.app.id
  }

  secret {
    name  = "appinsights-connection-string"
    value = azurerm_application_insights.this.connection_string
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 1

    container {
      name   = "app"
      image  = var.container_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
      }
      env {
        name  = "AZURE_OPENAI_ENDPOINT"
        value = azurerm_cognitive_account.openai.endpoint
      }
      env {
        name  = "AZURE_OPENAI_CHAT_DEPLOYMENT"
        value = azurerm_cognitive_deployment.chat.name
      }
      env {
        name  = "AZURE_OPENAI_EMBED_DEPLOYMENT"
        value = azurerm_cognitive_deployment.embedding.name
      }
      env {
        name  = "AZURE_SEARCH_ENDPOINT"
        value = "https://${azurerm_search_service.this.name}.search.windows.net"
      }
      env {
        name  = "AZURE_SEARCH_INDEX"
        value = local.index
      }
      env {
        name  = "GROUP_STAFF_ID"
        value = var.group_staff_id
      }
      env {
        name  = "GROUP_HR_ID"
        value = var.group_hr_id
      }
      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }
    }
  }

  lifecycle {
    # CI rolls out new images with `az containerapp update`.
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [time_sleep.rbac]
}

# Entra ID sign-in in front of the app (Container Apps built-in authentication).
resource "azapi_resource" "auth" {
  type      = "Microsoft.App/containerApps/authConfigs@2024-03-01"
  name      = "current"
  parent_id = azurerm_container_app.this.id

  body = {
    properties = {
      platform = { enabled = true }
      globalValidation = {
        unauthenticatedClientAction = "RedirectToLoginPage"
        redirectToProvider          = "azureactivedirectory"
      }
      identityProviders = {
        azureActiveDirectory = {
          enabled = true
          registration = {
            clientId                = var.web_client_id
            clientSecretSettingName = "microsoft-provider-authentication-secret"
            openIdIssuer            = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
          }
        }
      }
    }
  }
}
