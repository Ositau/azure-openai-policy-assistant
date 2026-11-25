# Bootstrap layer: everything the pipeline must NOT be able to create itself.
#  - Terraform remote state store
#  - Entra ID objects (groups, sign-in app registration, pipeline identity)
#  - The empty app resource group, Key Vault and container registry
#  - Least-privilege role assignments for the pipeline identity
# Result: the pipeline needs no Microsoft Graph permissions at all.

data "azurerm_client_config" "current" {}
data "azuread_client_config" "current" {}
data "azurerm_subscription" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result
}

# ---------- Terraform state ----------

resource "azurerm_resource_group" "state" {
  name     = var.state_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "state" {
  name                            = "sttfpolicyasst${local.suffix}"
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false # Entra ID auth only
  allow_nested_items_to_be_public = false
  tags                            = var.tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 14
    }
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# ---------- App resource group, Key Vault, registry ----------

resource "azurerm_resource_group" "app" {
  name     = var.app_resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_key_vault" "app" {
  name                       = "kv-policyasst-${local.suffix}"
  location                   = azurerm_resource_group.app.location
  resource_group_name        = azurerm_resource_group.app.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false # demo only; enable for real workloads
  soft_delete_retention_days = 7
  tags                       = var.tags
}

resource "azurerm_container_registry" "app" {
  name                = "crpolicyassistant${local.suffix}"
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# ---------- Entra ID: demo groups ----------

resource "azuread_group" "demo" {
  for_each = {
    staff = "Policy Assistant - Staff"
    hr    = "Policy Assistant - HR"
  }
  display_name     = each.value
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_group_member" "me" {
  for_each         = var.demo_user_groups
  group_object_id  = azuread_group.demo[each.key].object_id
  member_object_id = data.azuread_client_config.current.object_id
}

# ---------- Entra ID: sign-in app registration (Container Apps Easy Auth) ----------

resource "azuread_application" "web" {
  display_name            = "Policy Assistant (demo)"
  sign_in_audience        = "AzureADMyOrg"
  owners                  = [data.azuread_client_config.current.object_id]
  group_membership_claims = ["SecurityGroup"]

  web {
    redirect_uris = var.redirect_domain == "" ? [] : [
      "https://ca-policy-assistant.${var.redirect_domain}/.auth/login/aad/callback"
    ]
    implicit_grant {
      id_token_issuance_enabled = true
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "web" {
  client_id = azuread_application.web.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "web" {
  application_id = azuread_application.web.id
  display_name   = "container-apps-easy-auth"
  end_date       = timeadd(timestamp(), "2160h") # 90 days

  lifecycle {
    ignore_changes = [end_date]
  }
}

resource "azurerm_role_assignment" "me_kv_secrets" {
  scope                = azurerm_key_vault.app.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "kv_rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.me_kv_secrets]
}

# The app reads this through its managed identity; the secret never appears in the pipeline.
resource "azurerm_key_vault_secret" "easy_auth" {
  name         = "easy-auth-client-secret"
  value        = azuread_application_password.web.value
  key_vault_id = azurerm_key_vault.app.id
  depends_on   = [time_sleep.kv_rbac]
}

# ---------- Entra ID: pipeline identity (workload identity federation, no secret) ----------

resource "azuread_application" "pipeline" {
  display_name = "Policy Assistant pipeline (Azure DevOps)"
  owners       = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "pipeline" {
  client_id = azuread_application.pipeline.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "ado" {
  application_id = azuread_application.pipeline.id
  display_name   = "azure-devops-service-connection"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = var.ado_wif_issuer
  subject        = var.ado_wif_subject
}

# ---------- Least-privilege RBAC for the pipeline ----------

resource "azurerm_role_assignment" "pipeline_contributor" {
  scope                = azurerm_resource_group.app.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.pipeline.object_id
  principal_type       = "ServicePrincipal"
}

# The pipeline may create role assignments in the app resource group, but ONLY for these roles.
data "azurerm_role_definition" "assignable" {
  for_each = toset([
    "Cognitive Services OpenAI User",
    "Search Index Data Reader",
    "Search Index Data Contributor",
    "Search Service Contributor",
    "AcrPull",
    "Key Vault Secrets User",
  ])
  name  = each.value
  scope = data.azurerm_subscription.current.id
}

locals {
  assignable_ids = join(", ", [for r in data.azurerm_role_definition.assignable : r.role_definition_id])
  rbac_condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_ids}}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_ids}}
     )
    )
  EOT
}

resource "azurerm_role_assignment" "pipeline_rbac_admin" {
  scope                = azurerm_resource_group.app.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.pipeline.object_id
  principal_type       = "ServicePrincipal"
  condition            = local.rbac_condition
  condition_version    = "2.0"
}

resource "azurerm_role_assignment" "pipeline_state" {
  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.pipeline.object_id
  principal_type       = "ServicePrincipal"
}

# You run Terraform locally too (plan, troubleshooting): same state access.
resource "azurerm_role_assignment" "me_state" {
  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
