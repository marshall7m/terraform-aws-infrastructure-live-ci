# Upgrades

- Replace AWS API Gateway resources with Lambda Function URLs. With the recent release of [AWS Lambda Function URLs](https://aws.amazon.com/blogs/aws/announcing-aws-lambda-function-urls-built-in-https-endpoints-for-single-function-microservices/), Lambda Functions can now be invoked by their own HTTPS endpoint. Given the module only needs endpoints for simple webhook events, the Lambda Function URLs are a better fit than the AWS API Gateway. This removes the cost and management of the API Gateway resources within the module. With the removal of the API, comes the removal of the `github_webhook_validator` module. The request authentification logic that was performed within the validator Lambda Function will now be migrated into the receiver Lambda Function. Since the Lambda Function now doesn't have an API's request integration that adds the approriate headers, the approval_template.html file includes an inline Javascript ajax script to add the headers to the approval request.


Function URL security risks:
    - Given the function URL is public, if an attacker get a hold on the correct URL, the attack can execute an DDOS attack using the URL and max out the reserved concurrency limit for the Lambda Function resulting in higher execution cost
        Possible Solutions:
            - Have a Cloudwatch alarm notify when the Lambda function invocation count passes a specified threshold over a duration of time
            - Have a script that automatically creates a new Lambda URL and updates the URL for the webhook source

## TODO:
- Use `AWS_IAM` authentification for the Lambda Function URL and create a presigned function URL using an machine user credentials that is allowed to invoke the URL. The URL will use AWS V4 signature authentifaction that's provided within the query params since the headers are predetermined by the webhook source. The signature will have to not include the payload since the payload is dynamic. 

Steps:
    - create a machine IAM user that will sign the approval request query parameter authorization
    - user will need iam permission to invoke function
    - module will provision the machine user
    - machine user will be stored as a ssm secure string as {"key": <key>, "secret": <secret>}
    - approval request will use the access key to create the aws v4 query string