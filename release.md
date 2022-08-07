# Upgrades

- Replace AWS API Gateway resources with Lambda Function URLs. With the recent release of [AWS Lambda Function URLs](https://aws.amazon.com/blogs/aws/announcing-aws-lambda-function-urls-built-in-https-endpoints-for-single-function-microservices/), Lambda Functions can now be invoked by their own HTTPS endpoint. Given the module only needs endpoints for simple webhook events, the Lambda Function URLs are a better fit than the AWS API Gateway. This removes the cost and management of the API Gateway resources within the module. 
- With the deletion of the API, comes the removal of the `github_webhook_validator` module. The request authentification logic that was performed within the validator Lambda Function will now be migrated into the receiver Lambda Function.
