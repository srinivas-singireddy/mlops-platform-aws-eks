output "vpc_id" { value = module.vpc.vpc_id }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "nat_instance_id" { value = module.vpc.nat_instance_id }
output "nat_instance_eip" { value = module.vpc.nat_instance_eip }
