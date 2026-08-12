resource "aws_instance" "frontend" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.frontend_sg.id]
  key_name                    = aws_key_pair.main.key_name
  associate_public_ip_address = true

  tags = {
    Name = "frontend"
  }
}

resource "aws_instance" "backend" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private_subnet_backend.id
  vpc_security_group_ids      = [aws_security_group.backend_sg.id]
  key_name                    = aws_key_pair.main.key_name
  associate_public_ip_address = false

  tags = {
    Name = "backend"
  }
}

resource "aws_instance" "worker" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private_subnet_worker.id
  vpc_security_group_ids      = [aws_security_group.worker_sg.id]
  key_name                    = aws_key_pair.main.key_name
  associate_public_ip_address = false

  tags = {
    Name = "worker"
  }
}
