provider "aws" {
  region = "us-east-1"
}

locals {
    name = "project-1"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name = "${local.name}-vpc"
  cidr = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  single_nat_gateway = true
  enable_vpn_gateway = true
  tags = {
    Terraform = "true"
    Environment = "dev"
    Name = local.name
  }
}

# create security group
resource "aws_security_group" "web_sg" {
  name        = "${local.name}-app-sg"
  description = "Security group for web servers"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description = "frondend http access"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
      Name = "${local.name}-app-sg"
      Environment = "dev"
  }
}

# create security group
resource "aws_security_group" "lb_sg" {
  name        = "${local.name}-lb-sg"
  description = "Security group for web servers"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description = "frondend https access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
      Name = "${local.name}-lb-sg"
      Environment = "dev"
  }
}

# Create IAM role for Jenkins server to assume  SSM role
resource "aws_iam_role" "ssm-asg-role" {
  name = "${local.name}-ssm-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach  AmazonSSMManaged policy to asg IAM role
resource "aws_iam_role_policy_attachment" "asg_ssm" {
  role       = aws_iam_role.ssm-asg-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach  SecretsManagerReadWrite policy to asg IAM role
resource "aws_iam_role_policy_attachment" "asg_sm" {
  role       = aws_iam_role.ssm-asg-role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# Attach  SecretsManagerReadWrite policy to asg IAM role
resource "aws_iam_role_policy_attachment" "asg_ec2" {
  role       = aws_iam_role.ssm-asg-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# CREATE asg PROFILE FOR asg SERVER
resource "aws_iam_instance_profile" "ssm_instance_profile" {
  name = "${local.name}-ssm-server-profile"
  role = aws_iam_role.ssm-asg-role.name
}

# create dat block for ami
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# create keypair RSA Key of size 4096 bits
resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

// creating team1 private key
resource "local_file" "Key" {
  content         = tls_private_key.key.private_key_pem
  filename        = "${local.name}-key.pem"
  file_permission = 600
}

// creating team1 public key 
resource "aws_key_pair" "key" {
  key_name   = "${local.name}-pub-key"
  public_key = tls_private_key.key.public_key_openssh
}

# Launch Template Configuration for EC2 Instances
resource "aws_launch_template" "prod_lnch_tmpl" {
  name_prefix   = "${local.name}-prod-tmpl"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.medium"
  key_name  = aws_key_pair.key.key_name
  user_data = base64encode(file("./script.sh"))
  block_device_mappings {
    device_name = "/dev/sda1"  # Typical root device name for Ubuntu AMIs
    ebs {
      volume_size = 100         # New size in GB (default is usually 8GB)
      volume_type = "gp3"      # Recommended modern volume type
      encrypted   = true       # Good practice to enable encryption
    }
  }
  monitoring {
    enabled = true
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.ssm_instance_profile.name
  }
  network_interfaces {
    security_groups = [aws_security_group.web_sg.id]
    associate_public_ip_address = true
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens = "required"
  }
}

resource "aws_autoscaling_group" "prod_autoscaling_grp" {
  name                      = "${local.name}-prod-asg"
  max_size                  = 3
  min_size                  = 1
  desired_capacity          = 1
  health_check_grace_period = 120
  health_check_type         = "EC2"
  force_delete              = true
  vpc_zone_identifier = [module.vpc.public_subnets[0], module.vpc.public_subnets[1]]
  target_group_arns   = [aws_lb_target_group.prod-target-group.arn]
  launch_template {
    id      = aws_launch_template.prod_lnch_tmpl.id
    version = "$Latest"
  }
  instance_refresh {
    strategy = "Rolling"  # Default (alternatives: "RollingWithAdditionalBatch")
    preferences {
      min_healthy_percentage = 90  # Keep 90% healthy during refresh
      instance_warmup        = 120 # Seconds to wait for new instances
    }
  }
  tag {
    key                 = "Name"
    value               = "${local.name}-prod-asg"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "prod_team1_asg_policy" {
  autoscaling_group_name = aws_autoscaling_group.prod_autoscaling_grp.name
  name                   = "${local.name}-prod-team1-asg-policy"
  adjustment_type        = "ChangeInCapacity"
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

resource "aws_lb" "main_elb" {
  name               = "${local.name}-loadbalancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = module.vpc.public_subnets
  tags = {
    Environment = "${local.name}-loadbalancer"
  }
}

resource "aws_lb_target_group" "prod-target-group" {
  name        = "${local.name}-prod-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"
  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 5
    interval            = 30
    timeout             = 5
    path                = "/"
  }
  tags = {
    Name = "${local.name}-prod-tg"
  }
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main_elb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prod-target-group.arn
  }
}

resource "aws_secretsmanager_secret" "frontend_env" {
  name        = "frontend/env.front"
  description = "frontend environment variables"
  recovery_window_in_days = 7  # Optional: Set recovery window for secret deletion
   lifecycle {
    prevent_destroy = false  # Set to 'true' for production if you want to block deletion
  }
}
resource "aws_secretsmanager_secret_version" "frontend_env" {
  secret_id     = aws_secretsmanager_secret.frontend_env.id
  secret_string = var.frontend_env  # Reads local .env file
}

resource "aws_secretsmanager_secret" "backend_env" {
  name        = "backend/env.back"
  description = "backend environment variables"
  recovery_window_in_days = 7  # Optional: Set recovery window for secret deletion
   lifecycle {
    prevent_destroy = false  # Set to 'true' for production if you want to block deletion
  }
}
resource "aws_secretsmanager_secret_version" "backend_env" {
  secret_id     = aws_secretsmanager_secret.backend_env.id
  secret_string = var.backend_env   # Reads local .env file
}

output "front_secret_arn" {
  value       = aws_secretsmanager_secret.frontend_env.arn
  sensitive   = true
}

output "backend_secret_arn" {
  value       = aws_secretsmanager_secret.backend_env.arn
  sensitive   = true
}

variable "frontend_env" { type = string }
variable "backend_env" { type = string }