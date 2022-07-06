from diagrams import Cluster, Diagram, Edge
from diagrams.aws.database import Aurora
from diagrams.aws.network import APIGateway
from diagrams.aws.compute import LambdaFunction, Fargate
from diagrams.aws.integration import StepFunctions
from diagrams.aws.engagement import SimpleEmailServiceSesEmail
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import SystemsManagerParameterStore


with Diagram("diagram"):
    validator = LambdaFunction("2. Validate")
    receiver = LambdaFunction("3. Receiver")
    create_deploy_stack = Fargate("6. Create Deploy Stack")

    APIGateway("1. Webhook Payload") >> validator
    validator >> receiver
    (
        receiver
        >> Edge(label="Open", color="cornflowerblue", style="bold")
        >> [SystemsManagerParameterStore("4. Merge Lock"), Fargate("5. PR Plan")]
    )
    (
        receiver
        >> Edge(label="Merged", color="chartreuse3", style="bold")
        >> create_deploy_stack
    )

    with Cluster("Deployment Flow"):
        trigger_sf = LambdaFunction("7. Trigger Step Function")
        eventbridge = Eventbridge("12. Finished Execution")
        sf = StepFunctions()
        create_deploy_stack >> trigger_sf >> sf

        with Cluster("Step Function Execution"):
            plan = Fargate("8. Plan")
            request = LambdaFunction("9. Approval Request")
            email = SimpleEmailServiceSesEmail()
            response = LambdaFunction("10. Approval Response")
            apply = Fargate("11. Apply")

            sf >> [plan, eventbridge]
            eventbridge >> trigger_sf

            plan >> request >> email >> response >> apply

    Aurora("MetaDB") - [create_deploy_stack, trigger_sf, response, apply]
