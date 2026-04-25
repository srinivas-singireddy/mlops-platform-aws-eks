terraform {
  backend "s3" {
    bucket         = "mlops-tfstate-897175693580" # Your bucket name
    key            = "cluster/terraform.tfstate"  # Different key from network!
    region         = "eu-central-1"
    dynamodb_table = "mlops-tf-locks"
    encrypt        = true
    profile        = "mlops-platform"
  }
}
