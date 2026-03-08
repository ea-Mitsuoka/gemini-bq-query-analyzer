terraform {
  required_version = ">= 1.5.0"
  # backend設定は generate_configs.py によって backend.tf として自動生成されます

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "google" {
  project = var.saas_project_id
  region  = var.region
}

