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
  http_method   = "POST"
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

  depends_on = [
    aws_api_gateway_integration.approval
  ]
}

resource "aws_api_gateway_method_response" "response_302" {
  rest_api_id = aws_api_gateway_rest_api.approval.id
  resource_id = aws_api_gateway_resource.approval.id
  http_method = aws_api_gateway_method.approval.http_method

  status_code = "302"
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

  lifecycle {
    create_before_destroy = true
  }

  triggers = {
    redeployment = filesha1("${path.module}/approval.tf")
  }

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

data "archive_file" "lambda_approval_request" {
  type        = "zip"
  source_dir  = "${path.module}/functions/approval_request"
  output_path = "${path.module}/approval_request.zip"
}

module "lambda_approval_request" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_approval_request.output_path
  source_code_hash = data.archive_file.lambda_approval_request.output_base64sha256
  function_name    = "${var.step_function_name}-request"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  env_vars = {
    SENDER_EMAIL_ADDRESS = var.approval_request_sender_email
    SES_TEMPLATE         = aws_ses_template.approval.name
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
  statements = [
    {
      sid    = "SESSendAccess"
      effect = "Allow"
      actions = [
        "SES:SendRawEmail"
      ]
      resources = [aws_ses_email_identity.approval.arn]
    }
  ]
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
  function_name    = "${var.step_function_name}-response"
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  allowed_to_invoke = [
    {
      principal = "apigateway.amazonaws.com"
    }
  ]

  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
  ]
}

resource "aws_ses_email_identity" "approval" {
  email = var.approval_request_sender_email
}

data "aws_iam_policy_document" "approval" {
  statement {
    actions   = ["ses:SendEmail", "ses:SendBulkTemplatedEmail"]
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

resource "aws_ses_template" "approval" {
  name    = "${var.step_function_name}-approval"
  subject = "${var.step_function_name} Approval for path: {{path}}"
  html    = <<EOF
<form action="{{full_approval_api}}" method="post">
<label for="action">Choose an action:</label>
<select name="action" id="action">
<option value="approve">Approve</option>
<option value="reject">Reject</option>
</select>
<textarea name="comments" id="comments" style="width:96%;height:90px;background-color:lightgrey;color:black;border:none;padding:2%;font:14px/30px sans-serif;">
Reasoning for action
</textarea>
<input type="hidden" id="recipient" name="recipient" value="{{email_address}}">
<input type="submit" value="Submit" style="background-color:red;color:white;padding:5px;font-size:18px;border:none;padding:8px;">
</form>
  EOF
}