# Values from infra/bootstrap (stored in the Azure DevOps variable group).

variable "resource_group_name" {
  description = "App resource group created by the bootstrap layer."
  type        = string
}

variable "key_vault_name" {
  description = "Key Vault holding the Easy Auth client secret (bootstrap layer)."
  type        = string
}

variable "acr_name" {
  description = "Container registry (bootstrap layer)."
  type        = string
}

variable "group_staff_id" {
  type = string
}

variable "group_hr_id" {
  type = string
}

variable "web_client_id" {
  description = "Client ID of the sign-in app registration (bootstrap layer)."
  type        = string
}

variable "demo_user_object_id" {
  description = "Optional: a person who runs ingest/eval locally. Gets the same data-plane roles as the pipeline."
  type        = string
  default     = ""
}

# Deployment settings

variable "container_image" {
  description = "Image used when the Container App is first created. Later releases are rolled out by the app pipeline."
  type        = string
}

variable "chat_model" {
  type = object({ name = string, version = string, capacity = number })
  default = {
    name     = "gpt-4o-mini"
    version  = "2024-07-18"
    capacity = 30 # thousands of tokens per minute
  }
}

variable "embedding_model" {
  type = object({ name = string, version = string, capacity = number })
  default = {
    name     = "text-embedding-3-small"
    version  = "1"
    capacity = 30
  }
}

variable "deployment_sku" {
  description = "DataZoneStandard keeps inference inside the EU data zone."
  type        = string
  default     = "DataZoneStandard"
}

variable "tags" {
  type = map(string)
  default = {
    project     = "policy-assistant"
    environment = "demo"
    managed_by  = "terraform"
  }
}
