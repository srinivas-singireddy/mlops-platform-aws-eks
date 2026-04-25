# Read outputs from the network module's remote state
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket  = "mlops-tfstate-897175693580" # Your bucket name
    key     = "network/terraform.tfstate"
    region  = "eu-central-1"
    profile = "mlops-platform"
  }
}

data "aws_caller_identity" "current" {}
