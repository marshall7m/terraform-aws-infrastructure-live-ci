resource "aws_cloudwatch_event_rule" "pipeline" {
  name        = "${var.pipeline_name}-pipeline-execution"
  description = "Captures pipeline-level events for AWS CodePipeline: ${var.pipeline_name}"

  event_pattern = <<EOF
{
"source": [
    "aws.codepipeline"
  ],
  "detail-type": [
    "CodePipeline Pipeline Execution State Change"
  ],
  "detail": {
    "pipeline": ["${var.pipeline_name}"]
  }
}
EOF
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule      = aws_cloudwatch_event_rule.pipeline.name
  target_id = "SendToSF"
  arn       = 
}


resource "aws_sfn_state_machine" "sfn_state_machine" {
  name     = "my-state-machine"
  role_arn = aws_iam_role.iam_for_sfn.arn

  definition = <<EOF
{
  "StartAt": "PollCP",
  "States": {
    "PollCP": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.lambda.arn}"
    },
    "UpdateCP": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.lambda.arn}"
    }
    #updates CP and runs Update CP with other cfg dirs if the CP cfg change
  }
}
EOF
}