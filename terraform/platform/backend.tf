terraform {
  backend "s3" {
    bucket         = "mlops-tfstate-897175693580"
    key            = "platform/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "mlops-tf-locks"
    encrypt        = true
    profile        = "mlops-platform"
  }
}
