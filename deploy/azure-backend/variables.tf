// --- Identity / region ------------------------------------------------------

variable "resource_group_name" {
  description = "Resource group that holds the entire deployment. Created by Terraform; safe to teardown with terraform destroy."
  type        = string
  default     = "apollo-backend-rg"
}

variable "location" {
  description = "Azure region. South Central US is the cheapest Postgres Burstable in the US west."
  type        = string
  default     = "southcentralus"
}

variable "name_prefix" {
  description = "Resource name prefix. Lowercase, no underscores; used in DNS names."
  type        = string
  default     = "apollo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}$", var.name_prefix))
    error_message = "name_prefix must be 2-13 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

// --- Apple Push --------------------------------------------------------------

variable "apple_apns_topic" {
  description = "Bundle ID of the sideloaded Apollo build. MUST exactly match the IPA's CFBundleIdentifier."
  type        = string

  validation {
    condition     = var.apple_apns_topic != "com.christianselig.Apollo"
    error_message = "Use your custom bundle ID, not the original. Reddit's WAF blocks the original string in User-Agents on oauth.reddit.com."
  }
}

variable "apple_team_id" {
  description = "Apple Developer Team ID. 10 alphanumeric characters."
  type        = string

  validation {
    condition     = can(regex("^[A-Z0-9]{10}$", var.apple_team_id))
    error_message = "apple_team_id must be exactly 10 uppercase alphanumeric characters."
  }
}

variable "apple_key_id" {
  description = "APNs Auth Key ID. 10 alphanumeric characters."
  type        = string

  validation {
    condition     = can(regex("^[A-Z0-9]{10}$", var.apple_key_id))
    error_message = "apple_key_id must be exactly 10 uppercase alphanumeric characters."
  }
}

variable "apple_key_pem" {
  description = "Contents of the .p8 APNs Auth Key (PEM-encoded, multi-line)."
  type        = string
  sensitive   = true
}

variable "apple_apns_sandbox" {
  description = "Use APNs sandbox gateway. MUST be true for dev-signed sideloads — otherwise BadDeviceToken and the worker silently auto-deletes the device row."
  type        = bool
  default     = true
}

// --- Reddit OAuth ------------------------------------------------------------

variable "reddit_client_id" {
  description = "Reddit OAuth Client ID. Installed-app credentials are fine."
  type        = string
  sensitive   = true
}

variable "reddit_client_secret" {
  description = "Reddit OAuth Client Secret. Empty for installed-app credentials."
  type        = string
  sensitive   = true
  default     = ""
}

variable "reddit_redirect_uri" {
  description = "Reddit OAuth redirect URI."
  type        = string
  default     = "apollo://reddit-oauth"
}

variable "reddit_user_agent" {
  description = "Reddit User-Agent. Reddit requires the literal \"(by /u/<username>)\" suffix."
  type        = string

  validation {
    condition     = can(regex("\\(by /u/", var.reddit_user_agent))
    error_message = "reddit_user_agent must include the literal \"(by /u/<username>)\" suffix per Reddit API policy."
  }
}

// --- Backend image -----------------------------------------------------------

variable "backend_image" {
  description = "Apollo backend container image. Pin to a SHA for reproducibility once you're past initial deploy."
  type        = string
  default     = "ghcr.io/apollo-reborn/apollo-backend:latest"
}

// --- Schema bootstrap --------------------------------------------------------

variable "schema_source_ref" {
  description = "Git ref of apollo-backend repo to fetch docs/schema.sql and migrations/000013_*.sql from."
  type        = string
  default     = "main"
}
