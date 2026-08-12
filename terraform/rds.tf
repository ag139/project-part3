resource "aws_db_subnet_group" "main" {
  name = "main-db-subnet-group"

  subnet_ids = [
    aws_subnet.private_subnet_backend.id,
    aws_subnet.private_subnet_worker.id
  ]

  tags = {
    Name = "main-db-subnet-group"
  }
}

resource "aws_db_instance" "postgres" {
  identifier        = "project-db"
  engine            = "postgres"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  db_name           = "projectdb"

  username = var.db_username
  password = var.db_password

  db_subnet_group_name = aws_db_subnet_group.main.name

  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  publicly_accessible = false
  skip_final_snapshot = true
}
