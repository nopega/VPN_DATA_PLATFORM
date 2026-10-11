# PostgreSQL 17 for the Polaris catalog and Airflow metadata -- the same
# engine, version and size as the original platform.
#
# Private subnets only, no public address. Reachable from:
#   - pods in the cluster (they are in the VPC)
#   - your Mac over Tailscale, through the router (for creating the
#     databases and users, next step)

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-db"
  subnet_ids = local.private_subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.project_name}-db"
  description = "PostgreSQL from inside the VPC (pods, and the Tailscale router)"
  vpc_id      = local.vpc_id
  tags        = { Name = "${var.project_name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_vpc" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from the VPC"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
}

resource "aws_db_instance" "this" {
  identifier = "${var.project_name}-db"

  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  # Initial database. iceberg_catalog and airflow are created inside the
  # instance afterwards, each with its own user -- the apps never get the
  # master login.
  db_name  = "platform"
  username = "dbadmin"

  # RDS generates the master password and keeps it in Secrets Manager. It
  # never appears in this code or in terraform.tfstate. RDS also rotates it
  # (every 7 days by default), which is fine: only humans use the master
  # login, and they read the current value from the secret each time.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  # One day of point-in-time recovery, as the original.
  backup_retention_period = 1

  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Development platform: allow `terraform destroy` without ceremony.
  # Flip both before anything here holds data you would miss.
  deletion_protection = false
  skip_final_snapshot = true
}
