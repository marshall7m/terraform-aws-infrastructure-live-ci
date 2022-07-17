# Description

Create a slack approval bot to request infrastructure deployment approvals from specified slack users. Each Step Function execution will contain it's own slack thread containing the following post template:

```
Step Function execution <execution_id> needs approval for deploying infrastracture associated with the directory <cfg_path>

PR ID:
PR Link:
Terraform Plan Link
Infracost Breakdown

Approved:
<user avatar>

Rejected:
<user avatar>

Waiting on approval:
2 assignees: <user avatar> <user avatar>
```

Steps:

1. Lambda approve request function will connect to the slack bot and post the approval thread
2. Approval bot will send a reply within the thread to each approver containing a button for each approval action (Approve | Reject)
3. Approver pushes an approval action which sends a PUT request to the AWS API gateway specifying the following data:
    - Slack Approval user ID
    - approval action
4. AWS API gateway will run the Lambda approval response function 
5. Lambda approval response function will:
    1. Update the action's metadb execution record approval count column
    2. Update the awaiting approval section of the thread topic
    3. Update the Approved or Rejection section depending on action
    4. Add a reply specifying what action the approver chose that shows the timestamp of when they approved/rejected
6.



## Think about...

Will this replace or coexist with the email approval?

# TODO

- Experiment with Slack python SDK
- Create execution approval thread template
- Create approval response handling
- Create Terraform module integration
- Figure out how to create integration tests for slack
    - Create testing slack account/channel
    - Ping the button endpoint to test action functionality


Use App Manifest to allow module user to configure their own version of slack app programatically



# Module User Steps

1. Create Slack App (possibly via App manifest)
2. Invite Slack App bot via `/invite @<App Name>

api methods:

/approval/slack/vote
    - Lambda Function
        - update metadb record
        - send task token if met

/approval/ses/vote
    - Lambda Function
        - update approved|rejected section
        - update waiting on section
        - update metadb record
        - send task token if met


testing
spin up rest api resources and response function only


create wrapper functions over response functions to allow local web client to run response functions
then pass templated request to lambda function


replace API gateway with lambda endpoint URLs
- use var.authorization_type = "NONE" within lambda modules
use for functions:
    - lambda approval response
    - lambda receiver
incorporate gh validator authorization logic into each lambda function
