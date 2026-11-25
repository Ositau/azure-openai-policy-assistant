variable "location" {
  type    = string
  default = "swedencentral"
}

variable "app_resource_group_name" {
  description = "Resource group the pipeline deploys into. Created here so the pipeline identity can be scoped to it."
  type        = string
  default     = "rg-policy-assistant-demo"
}

variable "state_resource_group_name" {
  type    = string
  default = "rg-policy-assistant-tfstate"
}

variable "ado_wif_issuer" {
  description = "Issuer shown by Azure DevOps when creating the service connection (Workload identity federation, manual)."
  type        = string
}

variable "ado_wif_subject" {
  description = "Subject identifier shown by Azure DevOps for the same service connection."
  type        = string
}

variable "demo_user_groups" {
  description = "Demo groups the person applying this layer belongs to: [\"staff\"] or [\"staff\", \"hr\"]."
  type        = set(string)
  default     = ["staff"]

  validation {
    condition     = length(setsubtract(var.demo_user_groups, ["staff", "hr"])) == 0
    error_message = "Allowed values are \"staff\" and \"hr\"."
  }
}

variable "redirect_domain" {
  description = "Container Apps environment default domain, from the pipeline layer output `easy_auth_redirect_domain`. Leave empty on the first apply."
  type        = string
  default     = ""
}

variable "tags" {
  type = map(string)
  default = {
    project     = "policy-assistant"
    environment = "demo"
    managed_by  = "terraform-bootstrap"
  }
}
