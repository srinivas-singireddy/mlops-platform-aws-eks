output "state_bucket_name" {

  description = "S3 bucket holding Terraform state for downstream modules"
  value       = aws_s3_bucket.tf_state.id

}

output "state_lock_table_name" {

  description = "DynamoDB table used for state locking"
  value       = aws_dynamodb_table.tf_locks.name

}

output "region" {

  value = var.region

}
