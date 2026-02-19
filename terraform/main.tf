terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC and Networking (Simplified - 1 AZ to save costs)
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = { Name = "strapi-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "strapi-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = { Name = "strapi-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "strapi-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Groups
resource "aws_security_group" "alb" {
  name_prefix = "strapi-alb-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "strapi-alb-sg" }
}

resource "aws_security_group" "ecs" {
  name_prefix = "strapi-ecs-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 1337
    to_port         = 1337
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "strapi-ecs-sg" }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "strapi-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id]

  tags = { Name = "strapi-alb" }
}

resource "aws_lb_target_group" "main" {
  name        = "strapi-tg"
  port        = 1337
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path     = "/"
    interval = 30
    timeout  = 5
    matcher  = "200-299"
  }

  tags = { Name = "strapi-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ECR Repository
resource "aws_ecr_repository" "main" {
  name = "aman-strapi-repo"
  tags = { Name = "aman-strapi-repo" }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "aman-strapi-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "aman-strapi-cluster" }
}

# IAM Roles
resource "aws_iam_role" "ecs_execution" {
  name = "aman-strapi-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/aman-strapi"
  retention_in_days = 1  # Short retention for practice (save costs)

  tags = { Name = "aman-strapi-logs" }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "main" {
  family                   = "aman-strapi-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"   # Minimum for practice
  memory                   = "512"   # Minimum for practice
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name  = "strapi"
      image = "${aws_ecr_repository.main.repository_url}:latest"
      essential = true
      
      portMappings = [{
        containerPort = 1337
        protocol      = "tcp"
      }]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "DATABASE_CLIENT", value = "postgres" },  # SQLite for simplicity
        { name = "JWT_SECRET", value = "xjuQ7MTqUNi7BSlYPCq9pfxJJ0Tz0QadRind02+B6VY=" },
        { name = "ADMIN_JWT_SECRET", value = "YQDyUiLbVyblOWaSBYAdUQViF/CPrBZ7AKIeHXecdp0=" },
        { name = "APP_KEYS", value = "X8nSeDDOVFaiMKxGM2gyhg==,OQ8x061MRmwtnjDiAYfrOQ==,+6KZ/BQ1W6mVgzeh2zplFw==,0Q3X3lREGzouh4ebMhONKg==" },
        { name = "API_TOKEN_SALT", value = "wTJV3lwOWVR14H4QDpHbC5QM53xj6LeSkpjTpm7l0lw=" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = "strapi-task" }
}

# ECS Service
resource "aws_ecs_service" "main" {
  name            = "strapi-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = 1  # Single task for practice
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "strapi"
    container_port   = 1337
  }

  depends_on = [aws_lb_listener.http]
}

# CloudWatch Dashboard (Simple)
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "strapi-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.main.name]
          ]
          period = 300
          region = var.aws_region
          title  = "CPU Utilization"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.main.name]
          ]
          period = 300
          region = var.aws_region
          title  = "Memory Utilization"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "RunningTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.main.name]
          ]
          period = 60
          region = var.aws_region
          title  = "Running Tasks"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          query   = "SOURCE '/ecs/strapi' | fields @timestamp, @message | sort @timestamp desc | limit 20"
          region  = var.aws_region
          title   = "Recent Logs"
        }
      }
    ]
  })
}