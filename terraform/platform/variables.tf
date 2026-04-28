variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "aws_profile" {
  type    = string
  default = "mlops-platform"
}

variable "letsencrypt_email" {
  type        = string
  description = "Email for Let's Encrypt account registration (cert renewal notices go here)"
  default     = "singireddymail@gmail.com" # Change if you prefer a different one
}

variable "argocd_admin_password_bcrypt" {
  type        = string
  sensitive   = true
  description = "bcrypt hash of the ArgoCD admin password. Generate with: htpasswd -nbBC 10 \"\" YOURPASSWORD | tr -d ':\\n' | sed 's/\\$2y/\\$2a/'"
  default     = "" # Empty default = use ArgoCD's auto-generated password (see verification step)
}
