locals {
  approval_resources_name = "${var.step_function_name}-approval"
}
resource "aws_api_gateway_rest_api" "approval" {
  name        = local.approval_resources_name
  description = "HTTP Endpoint backed by API Gateway and Lambda used for Step Function approval"
}

resource "aws_api_gateway_resource" "approval" {
  rest_api_id = aws_api_gateway_rest_api.approval.id
  parent_id   = aws_api_gateway_rest_api.approval.root_resource_id
  path_part   = "approval"
}

resource "aws_api_gateway_method" "approval" {
  rest_api_id   = aws_api_gateway_rest_api.approval.id
  resource_id   = aws_api_gateway_resource.approval.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_method_settings" "approval" {
  rest_api_id = aws_api_gateway_rest_api.approval.id
  stage_name  = aws_api_gateway_stage.approval.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled    = true
    logging_level      = "INFO"
    data_trace_enabled = true
  }
}

resource "aws_api_gateway_integration" "approval" {
  rest_api_id             = aws_api_gateway_rest_api.approval.id
  resource_id             = aws_api_gateway_resource.approval.id
  http_method             = aws_api_gateway_method.approval.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = module.lambda_approval_response.function_invoke_arn

  request_templates = {
    "application/json" = <<EOF
{
  "body" : $input.json('$'),
  "headers": {
    #foreach($header in $input.params().header.keySet())
    "$header": "$util.escapeJavaScript($input.params().header.get($header))" #if($foreach.hasNext),#end

    #end
  },
  "method": "$context.httpMethod",
  "params": {
    #foreach($param in $input.params().path.keySet())
    "$param": "$util.escapeJavaScript($input.params().path.get($param))" #if($foreach.hasNext),#end

    #end
  },
  "query": {
    #foreach($queryParam in $input.params().querystring.keySet())
    "$queryParam": "$util.escapeJavaScript($input.params().querystring.get($queryParam))" #if($foreach.hasNext),#end

    #end
  }  
}
  EOF
  }
}


resource "aws_api_gateway_integration_response" "approval" {
  rest_api_id = aws_api_gateway_rest_api.approval.id
  resource_id = aws_api_gateway_resource.approval.id
  http_method = aws_api_gateway_method.approval.http_method

  status_code = aws_api_gateway_method_response.response_302.status_code
  response_parameters = {
    "method.response.header.Location" = "integration.response.body.headers.Location"
  }

  depends_on = [
    aws_api_gateway_integration.approval
  ]
}

resource "aws_api_gateway_method_response" "response_302" {
  rest_api_id = aws_api_gateway_rest_api.approval.id
  resource_id = aws_api_gateway_resource.approval.id
  http_method = aws_api_gateway_method.approval.http_method

  status_code = "302"
  response_parameters = {
    "method.response.header.Location" = true
  }
}

resource "aws_api_gateway_account" "approval" {
  cloudwatch_role_arn = module.agw_role.role_arn
}

module "agw_role" {
  source = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"

  role_name        = "agw-logs"
  trusted_services = ["apigateway.amazonaws.com"]

  statements = [
    {
      sid    = "CloudWatchAccess"
      effect = "Allow"
      actions = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
        "logs:GetLogEvents",
        "logs:FilterLogEvents"
      ]
      resources = ["*"]
    }
  ]
}

resource "aws_cloudwatch_log_group" "agw" {
  name = local.approval_resources_name
}

resource "aws_api_gateway_deployment" "approval" {
  rest_api_id = aws_api_gateway_rest_api.approval.id

  depends_on = [
    aws_api_gateway_resource.approval,
    aws_api_gateway_method.approval,
    aws_api_gateway_method_response.response_302,
    aws_api_gateway_integration.approval,
    aws_api_gateway_integration_response.approval
  ]
}

resource "aws_api_gateway_stage" "approval" {
  deployment_id = aws_api_gateway_deployment.approval.id
  rest_api_id   = aws_api_gateway_rest_api.approval.id
  stage_name    = "prod"
}


data "archive_file" "lambda_approval_response" {
  type        = "zip"
  source_dir  = "${path.module}/functions/approval_response"
  output_path = "${path.module}/approval_response.zip"
}

module "lambda_approval_response" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_approval_response.output_path
  source_code_hash = data.archive_file.lambda_approval_response.output_base64sha256
  function_name    = local.approval_resources_name
  handler          = "lambda_handler"
  runtime          = "python3.8"
  env_vars = {
    ARTIFACT_BUCKET_NAME = aws_s3_bucket.artifacts.id
  }
}

data "archive_file" "lambda_approval_request" {
  type        = "zip"
  source_dir  = "${path.module}/functions/approval_request"
  output_path = "${path.module}/approval_request.zip"
}

module "lambda_approval_request" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_approval_request.output_path
  source_code_hash = data.archive_file.lambda_approval_request.output_base64sha256
  function_name    = "infrastructure-live-approval-request"
  handler          = "lambda_handler"
  runtime          = "python3.8"
  env_vars = {
    APPROVAL_API         = "${aws_api_gateway_deployment.approval.invoke_url}${aws_api_gateway_resource.approval.path}"
    SENDER_EMAIL_ADDRESS = var.approval_request_sender_email
  }
}


resource "aws_ses_email_identity" "approval" {
  email = var.approval_request_sender_email
}

data "aws_iam_policy_document" "approval" {
  statement {
    actions   = ["SES:SendEmail", "SES:SendRawEmail"]
    resources = [aws_ses_email_identity.approval.arn]

    principals {
      identifiers = ["*"]
      type        = "AWS"
    }
  }
}

resource "aws_ses_identity_policy" "approval" {
  identity = aws_ses_email_identity.approval.arn
  name     = "infrastructure-live-ses-approval"
  policy   = data.aws_iam_policy_document.approval.json
}