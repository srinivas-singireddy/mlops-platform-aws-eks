output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr" { value = aws_vpc.this.cidr_block }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "nat_instance_id" { value = aws_instance.nat.id }
output "nat_instance_eip" { value = aws_eip.nat.public_ip }
