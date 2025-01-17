

# ------------------------------------------------------------------------------
# Local configurations
# ------------------------------------------------------------------------------

locals {
  framework_version = var.pytorch_version != null ? var.pytorch_version : var.tensorflow_version != null ? var.tensorflow_version : var.tgi_version
  # set repository to hf-pt, hf-tf or tpi-inference
  huggingface_pytorch_inference = "huggingface-pytorch-inference"
  huggingface_tensorflow_inference = "huggingface-tensorflow-inference"
  huggingface_pytorch_tgi_inference = "huggingface-pytorch-tgi-inference"
  repository_name   = var.pytorch_version != null ? local.huggingface_pytorch_inference : var.tensorflow_version != null ? local.huggingface_tensorflow_inference : local.huggingface_pytorch_tgi_inference
  device            = length(regexall("^ml\\.[g|p{1,3}\\.$]", var.instance_type)) > 0 ? "gpu" : "cpu"
  image_key         = var.pytorch_version != null || var.tensorflow_version != null ? "${local.framework_version}-${local.device}" : local.framework_version
  pytorch_image_tag = {
    "1.7.1-gpu" = "1.7.1-transformers${var.transformers_version}-gpu-py36-cu110-ubuntu18.04"
    "1.7.1-cpu" = "1.7.1-transformers${var.transformers_version}-cpu-py36-ubuntu18.04"
    "1.8.1-gpu" = "1.8.1-transformers${var.transformers_version}-gpu-py36-cu111-ubuntu18.04"
    "1.8.1-cpu" = "1.8.1-transformers${var.transformers_version}-cpu-py36-ubuntu18.04"
    "1.9.1-gpu" = "1.9.1-transformers${var.transformers_version}-gpu-py38-cu111-ubuntu20.04"
    "1.9.1-cpu" = "1.9.1-transformers${var.transformers_version}-cpu-py38-ubuntu20.04"
    "1.13.1-cpu" = "1.13.1-transformers${var.transformers_version}-cpu-py39-ubuntu20.04"
    "1.13.1-gpu" = "1.13.1-transformers${var.transformers_version}-gpu-py39-cu117-ubuntu20.04"
  }
  tensorflow_image_tag = {
    "2.4.1-gpu" = "2.4.1-transformers${var.transformers_version}-gpu-py37-cu110-ubuntu18.04"
    "2.4.1-cpu" = "2.4.1-transformers${var.transformers_version}-cpu-py37-ubuntu18.04"
    "2.5.1-gpu" = "2.5.1-transformers${var.transformers_version}-gpu-py36-cu111-ubuntu18.04"
    "2.5.1-cpu" = "2.5.1-transformers${var.transformers_version}-cpu-py36-ubuntu18.04"
  }
  tgi_image_tag = {
    "1.1.0" = "2.0.1-tgi1.1.0-gpu-py39-cu118-ubuntu20.04"
    "0.9.3" = "2.0.1-tgi0.9.3-gpu-py39-cu118-ubuntu20.04"
    "0.8.2" = "2.0.0-tgi0.8.2-gpu-py39-cu118-ubuntu20.04"
  }
  sagemaker_endpoint_type = {
    real_time = (var.async_config.s3_output_path == null && var.serverless_config.max_concurrency == null) ? true : false
    asynchronous = (var.async_config.s3_output_path != null && var.serverless_config.max_concurrency == null) ? true : false
    serverless = (var.async_config.s3_output_path == null && var.serverless_config.max_concurrency != null) ? true : false
  }
}

# random lowercase string used for naming
resource "random_string" "ressource_id" {
  length  = 8
  lower   = true
  special = false
  upper   = false
  numeric  = false
}

# ------------------------------------------------------------------------------
# Container Image
# ------------------------------------------------------------------------------


data "aws_sagemaker_prebuilt_ecr_image" "deploy_image" {
  count           = local.repository_name == local.huggingface_pytorch_tgi_inference ? 0 : 1
  repository_name = local.repository_name
  image_tag       = var.pytorch_version != null ? local.pytorch_image_tag[local.image_key] : var.tensorflow_version != null ? local.tensorflow_image_tag[local.image_key] : local.tgi_image_tag[local.image_key]
}

# ------------------------------------------------------------------------------
# Permission
# ------------------------------------------------------------------------------

resource "aws_iam_role" "new_role" {
  count = var.sagemaker_execution_role == null ? 1 : 0 # Creates IAM role if not provided
  name  = "${var.name_prefix}-sagemaker-execution-role-${random_string.ressource_id.result}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
      },
    ]
  })

  inline_policy {
    name = "terraform-inferences-policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow",
          Action = [
            "cloudwatch:PutMetricData",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
            "logs:CreateLogGroup",
            "logs:DescribeLogStreams",
            "s3:GetObject",
            "s3:PutObject",
            "s3:ListBucket",
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ec2:DescribeVpcEndpoints",
            "ec2:DescribeDhcpOptions",
            "ec2:DescribeVpcs",
            "ec2:DescribeSubnets",
            "ec2:DescribeSecurityGroups",
            "ec2:DescribeNetworkInterfaces",
            "ec2:DeleteNetworkInterfacePermission",
            "ec2:DeleteNetworkInterface",
            "ec2:CreateNetworkInterfacePermission",
            "ec2:CreateNetworkInterface",
            "ec2:*"
          ],
          Resource = "*"
        },
      ]
    })

  }

  tags = var.tags
}

data "aws_iam_role" "get_role" {
  count = var.sagemaker_execution_role != null ? 1 : 0 # Creates IAM role if not provided
  name  = var.sagemaker_execution_role
}

locals {
  role_arn = var.sagemaker_execution_role != null ? data.aws_iam_role.get_role[0].arn : aws_iam_role.new_role[0].arn
}

# ------------------------------------------------------------------------------
# SageMaker Model
# ------------------------------------------------------------------------------

resource "aws_sagemaker_model" "model_with_model_artifact" {
  count              = var.model_data != null && var.hf_model_id == null ? 1 : 0
  name               = "${var.name_prefix}-model-${random_string.ressource_id.result}"
  execution_role_arn = local.role_arn
  tags               = var.tags

  primary_container {
    # CPU Image
    image          = data.aws_sagemaker_prebuilt_ecr_image.deploy_image[0].registry_path
    model_data_url = var.model_data
    environment = {
      HF_TASK = var.hf_task
    }
  }
}


resource "aws_sagemaker_model" "model_with_hub_model" {
  count              = var.model_data == null && var.hf_model_id != null ? 1 : 0
  name               = "${var.name_prefix}-model-${random_string.ressource_id.result}"
  execution_role_arn = local.role_arn
  tags               = var.tags
  dynamic "vpc_config" {
    for_each = var.security_group_ids != null && var.subnets != null ? [1] : []
    content {
      security_group_ids = var.security_group_ids
      subnets            = var.subnets
    }
  }

  primary_container {
    image = var.tgi_version != null ? "763104351884.dkr.ecr.us-east-1.amazonaws.com/huggingface-pytorch-tgi-inference:${local.tgi_image_tag[local.image_key]}" : data.aws_sagemaker_prebuilt_ecr_image.deploy_image[0].registry_path
    environment = {
      HF_TASK           = var.hf_task
      HF_MODEL_ID       = var.hf_model_id
      HF_API_TOKEN      = var.hf_api_token
      HF_MODEL_REVISION = var.hf_model_revision
      SM_NUM_GPUS       = var.num_gpus
      MAX_INPUT_LENGTH  = var.max_input_length
      MAX_TOTAL_TOKENS  = var.max_total_tokens
      HF_MODEL_QUANTIZE = var.quantization
    }
  }
}

locals {
  sagemaker_model = var.model_data != null && var.hf_model_id == null ? aws_sagemaker_model.model_with_model_artifact[0] : aws_sagemaker_model.model_with_hub_model[0]
}

# ------------------------------------------------------------------------------
# SageMaker Endpoint configuration
# ------------------------------------------------------------------------------

resource "aws_sagemaker_endpoint_configuration" "huggingface" {
  count = local.sagemaker_endpoint_type.real_time ? 1 : 0
  name  = "${var.name_prefix}-ep-config-${random_string.ressource_id.result}"
  tags  = var.tags


  production_variants {
    variant_name           = "AllTraffic"
    model_name             = local.sagemaker_model.name
    initial_instance_count = var.instance_count
    instance_type          = var.instance_type
  }
}


resource "aws_sagemaker_endpoint_configuration" "huggingface_async" {
  count = local.sagemaker_endpoint_type.asynchronous ? 1 : 0
  name  = "${var.name_prefix}-ep-config-${random_string.ressource_id.result}"
  tags  = var.tags


  production_variants {
    variant_name           = "AllTraffic"
    model_name             = local.sagemaker_model.name
    initial_instance_count = var.instance_count
    instance_type          = var.instance_type
  }
  async_inference_config {
    output_config {
      s3_output_path = var.async_config.s3_output_path
      kms_key_id     = var.async_config.kms_key_id
      # notification_config {
      #   error_topic   = var.async_config.sns_error_topic
      #   success_topic = var.async_config.sns_success_topic
      # }
    }
  }
}


resource "aws_sagemaker_endpoint_configuration" "huggingface_serverless" {
  count = local.sagemaker_endpoint_type.serverless ? 1 : 0
  name  = "${var.name_prefix}-ep-config-${random_string.ressource_id.result}"
  tags  = var.tags


  production_variants {
    variant_name           = "AllTraffic"
    model_name             = local.sagemaker_model.name

    serverless_config {
      max_concurrency   = var.serverless_config.max_concurrency
      memory_size_in_mb = var.serverless_config.memory_size_in_mb
    }
  }
}


locals {
  sagemaker_endpoint_config = (
    local.sagemaker_endpoint_type.real_time ?
      aws_sagemaker_endpoint_configuration.huggingface[0] : (
        local.sagemaker_endpoint_type.asynchronous ?
          aws_sagemaker_endpoint_configuration.huggingface_async[0] : (
            local.sagemaker_endpoint_type.serverless ?
              aws_sagemaker_endpoint_configuration.huggingface_serverless[0] : null
          )
      )
  )
}

# ------------------------------------------------------------------------------
# SageMaker Endpoint
# ------------------------------------------------------------------------------


resource "aws_sagemaker_endpoint" "huggingface" {
  name = "${var.name_prefix}-ep-${random_string.ressource_id.result}"
  tags = var.tags

  endpoint_config_name = local.sagemaker_endpoint_config.name
}

# ------------------------------------------------------------------------------
# AutoScaling configuration
# ------------------------------------------------------------------------------


locals {
  use_autoscaling = var.autoscaling.max_capacity != null && var.autoscaling.target_value != null && !local.sagemaker_endpoint_type.serverless ? 1 : 0
  use_predefined_metric = local.use_autoscaling != 0 && var.autoscaling.customized_metric == null ? 1 : 0
  use_customized_metric = local.use_autoscaling != 0 && var.autoscaling.customized_metric != null ? 1 : 0
}

resource "aws_appautoscaling_target" "sagemaker_target" {
  count              = local.use_autoscaling
  min_capacity       = var.autoscaling.min_capacity
  max_capacity       = var.autoscaling.max_capacity
  resource_id        = "endpoint/${aws_sagemaker_endpoint.huggingface.name}/variant/AllTraffic"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"
}

resource "aws_appautoscaling_policy" "sagemaker_policy" {
  count              = local.use_predefined_metric
  name               = "${var.name_prefix}-scaling-target-${random_string.ressource_id.result}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.sagemaker_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.sagemaker_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }
    target_value       = var.autoscaling.target_value
    scale_in_cooldown  = var.autoscaling.scale_in_cooldown
    scale_out_cooldown = var.autoscaling.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "sagemaker_custom_policy" {
  count              = local.use_customized_metric
  name               = "${var.name_prefix}-scaling-target-${random_string.ressource_id.result}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.sagemaker_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.sagemaker_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    customized_metric_specification {
      metric_name = var.autoscaling.customized_metric.metric_name
      namespace   = "AWS/SageMaker"
      statistic   = var.autoscaling.customized_metric.statistic
      dimensions {
        name  = "EndpointName"
        value = aws_sagemaker_endpoint.huggingface.name
      }
    }
    target_value       = var.autoscaling.target_value
    scale_in_cooldown  = var.autoscaling.scale_in_cooldown
    scale_out_cooldown = var.autoscaling.scale_out_cooldown
  }
}
