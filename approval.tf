locals {
  approval_request_name  = "${var.step_function_name}-request"
  approval_response_name = "${var.step_function_name}-response"
  approval_logs          = "${var.step_function_name}-approval"

  approval_response_deps_zip_path = replace("${path.module}/${local.approval_response_name}_deps.zip", "-", "_")
  approval_deps_dir               = "${path.module}/deps"
}

resource "aws_api_gateway_rest_api" "this" {
  name        = local.approval_logs
  description = "HTTP Endpoint backed by API Gateway that is used for handling PR merge lock status resquests and Step Function approvals"
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

  status_code = aws_api_gateway_method_response.response_302.status_code

  depends_on = [
    aws_api_gateway_integration.approval
  ]
}

resource "aws_api_gateway_method_response" "response_302" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.approval.id
  http_method = aws_api_gateway_method.approval.http_method

  status_code = "302"
}

resource "aws_api_gateway_account" "approval" {
  cloudwatch_role_arn = module.agw_role.role_arn
}

module "agw_role" {
  source = "github.com/marshall7m/terraform-aws-iam/modules//iam-role"

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

resource "aws_cloudwatch_log_group" "agw" {
  name = "aws/apigateway/${local.approval_logs}"
}

data "archive_file" "lambda_approval_request" {
  type        = "zip"
  source_dir  = "${path.module}/functions/approval_request"
  output_path = "${path.module}/approval_request.zip"
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
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_approval_request.output_path
  source_code_hash = data.archive_file.lambda_approval_request.output_base64sha256
  function_name    = local.approval_request_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"

  vpc_config = var.lambda_approval_request_vpc_config
  env_vars = {
    SENDER_EMAIL_ADDRESS = var.approval_request_sender_email
    SES_TEMPLATE         = aws_ses_template.approval.name
  }
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.lambda_approval_request.arn
  ]
}

data "archive_file" "lambda_approval_response" {
  type        = "zip"
  source_dir  = "${path.module}/functions/approval_response"
  output_path = "${path.module}/approval_response.zip"
}

# pip install runtime packages needed for function
resource "null_resource" "lambda_approval_response_deps" {
  triggers = {
    zip_hash = fileexists(local.approval_response_deps_zip_path) ? 0 : timestamp()
  }
  provisioner "local-exec" {
    command = <<EOF
    python3 -m pip install --target ${local.approval_deps_dir}/python aurora-data-api==0.4.0
    EOF
  }
}

data "archive_file" "lambda_approval_response_deps" {
  type        = "zip"
  source_dir  = local.approval_deps_dir
  output_path = local.approval_response_deps_zip_path
  depends_on = [
    null_resource.lambda_approval_response_deps
  ]
}

module "lambda_approval_response" {
  source           = "github.com/marshall7m/terraform-aws-lambda"
  filename         = data.archive_file.lambda_approval_response.output_path
  source_code_hash = data.archive_file.lambda_approval_response.output_base64sha256
  function_name    = local.approval_response_name
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.8"
  allowed_to_invoke = [
    {
      principal = "apigateway.amazonaws.com"
    }
  ]

  vpc_config = var.lambda_approval_response_vpc_config
  timeout    = 180

  env_vars = {
    METADB_NAME        = local.metadb_name
    METADB_CLUSTER_ARN = aws_rds_cluster.metadb.arn
    METADB_SECRET_ARN  = aws_secretsmanager_secret_version.ci_metadb_user.arn
  }

  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.ci_metadb_access.arn
  ]

  statements = [
    {
      sid       = "SendTaskSuccess"
      effect    = "Allow"
      actions   = ["states:SendTaskSuccess"]
      resources = [aws_sfn_state_machine.this.arn]
    }
  ]
  lambda_layers = [
    {
      filename         = data.archive_file.lambda_approval_response_deps.output_path
      name             = "${local.approval_response_name}-deps"
      runtimes         = ["python3.8"]
      source_code_hash = data.archive_file.lambda_approval_response_deps.output_base64sha256
      description      = "Dependencies for lambda function: ${local.approval_response_name}"
    }
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
  name    = local.approval_request_name
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