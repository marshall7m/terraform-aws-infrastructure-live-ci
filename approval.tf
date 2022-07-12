locals {
  approval_request_name  = "${var.prefix}-request"
  approval_response_name = "${var.prefix}-response"
  approval_logs          = "${var.prefix}-approval"
}

resource "aws_api_gateway_rest_api" "this" {
  name        = local.approval_logs
  description = "HTTP Endpoint backed by API Gateway that is used for handling GitHub webhook events and Step Function approvals"
}

resource "aws_api_gateway_resource" "approval" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "approval"
}

resource "aws_api_gateway_method" "approval" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.approval.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method_settings" "approval" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = module.github_webhook_validator.api_stage_name
  method_path = "*/*"

  settings {
    metrics_enabled    = true
    logging_level      = "INFO"
    data_trace_enabled = true
  }
}

resource "aws_api_gateway_integration" "approval" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.approval.id
  http_method             = aws_api_gateway_method.approval.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = module.lambda_approval_response.lambda_function_invoke_arn

  request_templates = {
    # converts to key-value pairs (e.g. {'action': 'accept', 'comments': 'Reasoning for action\r\n'})
    "application/x-www-form-urlencoded" = <<EOF
{
  "body": {
    #foreach( $token in $input.path('$').split('&') )
        #set( $keyVal = $token.split('=') )
        #set( $keyValSize = $keyVal.size() )
        #if( $keyValSize >= 1 )
            #set( $key = $util.urlDecode($keyVal[0]) )
            #if( $keyValSize >= 2 )
                #set( $val = $util.urlDecode($keyVal[1]) )
            #else
                #set( $val = '' )
            #end
            "$key": "$util.escapeJavaScript($val)"#if($foreach.hasNext),#end
        #end
    #end
    },
  "query": {
    #foreach($queryParam in $input.params().querystring.keySet())
      #if ( $queryParam == "taskToken" )
          "$queryParam": "$util.escapeJavaScript($input.params().querystring.get($queryParam).replaceAll(" ", "+"))"
      #else
          "$queryParam": "$util.escapeJavaScript($input.params().querystring.get($queryParam))" 
      #end
      #if($foreach.hasNext),#end
    #end
  }
}
  EOF
  }
}


resource "aws_api_gateway_integration_response" "approval" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.approval.id
  http_method = aws_api_gateway_method.approval.http_method

  status_code = aws_api_gateway_method_response.response_200.status_code

  depends_on = [
    aws_api_gateway_integration.approval
  ]
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.approval.id
  http_method = aws_api_gateway_method.approval.http_method

  status_code = "200"
}

resource "aws_api_gateway_account" "approval" {
  cloudwatch_role_arn = module.agw_role.role_arn
}

module "agw_role" {
  source = "github.com/marshall7m/terraform-aws-iam//modules/iam-role?ref=v0.1.0"

  role_name        = local.approval_logs
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

data "aws_iam_policy_document" "lambda_approval_request" {
  statement {
    sid    = "SESAccess"
    effect = "Allow"
    actions = [
      "ses:SendRawEmail",
      "ses:SendEmail"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ses:FromAddress"
      values   = [var.approval_request_sender_email]
    }

    condition {
      test     = "ForAllValues:StringLike"
      variable = "ses:Recipients"
      values   = flatten([for account in var.account_parent_cfg : account.voters])
    }
  }
}

resource "aws_iam_policy" "lambda_approval_request" {
  name        = "${local.approval_request_name}-ses-access"
  description = "Allows Lambda function to send SES emails to and from defined email addresses"
  policy      = data.aws_iam_policy_document.lambda_approval_request.json
}

module "lambda_approval_request" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "3.3.1"

  function_name = local.approval_request_name
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  source_path = "${path.module}/functions/approval_request"

  environment_variables = {
    SENDER_EMAIL_ADDRESS = var.approval_request_sender_email
    SES_TEMPLATE         = aws_ses_template.approval.name
  }

  publish = true
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.lambda_approval_request.arn
  ]
  attach_policies               = true
  number_of_policies            = 2
  role_force_detach_policies    = true
  attach_cloudwatch_logs_policy = true

  vpc_subnet_ids         = try(var.lambda_approval_request_vpc_config.subnet_ids, null)
  vpc_security_group_ids = try(var.lambda_approval_request_vpc_config.security_group_ids, null)
  attach_network_policy  = var.lambda_approval_request_vpc_config != null ? true : false
}


data "aws_iam_policy_document" "approval_response" {
  statement {
    effect    = "Allow"
    actions   = ["states:SendTaskSuccess"]
    resources = [aws_sfn_state_machine.this.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["states:DescribeExecution"]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "approval_response" {
  name        = "${local.approval_response_name}-sf-access"
  description = "Allows Lambda function to describe Step Function executions and send success task tokens to associated Step Function machine"
  policy      = data.aws_iam_policy_document.approval_response.json
}

module "lambda_approval_response" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "3.3.1"

  function_name = local.approval_response_name
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  source_path = [
    {
      path             = "${path.module}/functions/approval_response"
      pip_requirements = true
    }
  ]
  timeout = 180
  environment_variables = {
    METADB_NAME        = local.metadb_name
    METADB_CLUSTER_ARN = aws_rds_cluster.metadb.arn
    METADB_SECRET_ARN  = aws_secretsmanager_secret_version.ci_metadb_user.arn
  }

  allowed_triggers = {
    APIGatewayInvokeAccess = {
      service    = "apigateway"
      source_arn = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
    }
  }

  publish = true

  attach_policies               = true
  number_of_policies            = 3
  role_force_detach_policies    = true
  attach_cloudwatch_logs_policy = true
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.ci_metadb_access.arn,
    aws_iam_policy.approval_response.arn
  ]
  vpc_subnet_ids         = try(var.lambda_approval_response_vpc_config.subnet_ids, null)
  vpc_security_group_ids = try(var.lambda_approval_response_vpc_config.security_group_ids, null)
  attach_network_policy  = var.lambda_approval_response_vpc_config != null ? true : false
}

data "aws_ses_email_identity" "approval" {
  count = var.send_verification_email == false ? 1 : 0
  email = var.approval_request_sender_email
}

resource "aws_ses_email_identity" "approval" {
  count = var.send_verification_email ? 1 : 0
  email = var.approval_request_sender_email
}

data "aws_iam_policy_document" "approval" {
  statement {
    actions   = ["ses:SendEmail", "ses:SendBulkTemplatedEmail"]
    resources = [try(aws_ses_email_identity.approval[0].arn, data.aws_ses_email_identity.approval[0].arn)]

    principals {
      identifiers = ["*"]
      type        = "AWS"
    }
  }
}

resource "aws_ses_identity_policy" "approval" {
  identity = try(aws_ses_email_identity.approval[0].arn, data.aws_ses_email_identity.approval[0].arn)
  name     = "infrastructure-live-ses-approval"
  policy   = data.aws_iam_policy_document.approval.json
}

resource "aws_ses_template" "approval" {
  name    = local.approval_request_name
  subject = "${local.step_function_name} - Need Approval for Path: {{path}}"
  html    = file("${path.module}/approval_template.html")
}