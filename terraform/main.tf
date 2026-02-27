terraform {
  required_version = ">= 1.5.0"
  backend "gcs" {
    bucket = "your-terraform-state-bucket" # 事前にGCSに作成したtfstate管理用バケット名を手動で記載してください
    prefix = "terraform/state"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.saas_project_id
  region  = var.region
}
