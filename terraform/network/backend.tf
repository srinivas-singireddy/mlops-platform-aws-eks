terraform {
  backend "s3" {
    bucket         = "mlops-tfstate-938822141378"
    key            = "network/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "mlops-tf-locks"
    encrypt        = true
    profile        = "mlops-platform"
  }
}
