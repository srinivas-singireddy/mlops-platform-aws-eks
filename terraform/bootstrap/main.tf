terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
  # NOTE: No backend block here — bootstrap uses local state by design.
  # After `apply`, the terraform.tfstate file lives in this directory.
  # Commit-ignored via our .gitignore.
}

provider "aws" {

  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "mlops-platform"
      Environment = "lab"
      ManagedBy   = "terraform"
      Component   = "bootstrap"
    }
  }

}

# -----------------------------------------------------------------------------
# S3 bucket for Terraform state
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {

  bucket = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"

}

resource "aws_s3_bucket_versioning" "tf_state" {

  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"

  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {

  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }

}

resource "aws_s3_bucket_public_access_block" "tf_state" {

  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

}

# -----------------------------------------------------------------------------
# DynamoDB table for state locking
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "tf_locks" {

  name         = "${var.name_prefix}-tf-locks"
  billing_mode = "PAY_PER_REQUEST" # Pennies. Don't provision capacity.
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

}

data "aws_caller_identity" "current" {}
