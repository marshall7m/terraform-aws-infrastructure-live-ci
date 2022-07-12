from diagrams import Cluster, Diagram, Edge
from diagrams.aws.database import Aurora
from diagrams.aws.network import APIGateway
from diagrams.aws.compute import LambdaFunction, Fargate
from diagrams.aws.integration import StepFunctions
from diagrams.aws.engagement import SimpleEmailServiceSesEmail
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import SystemsManagerParameterStore

common_attr = {"fontsize": "25", "fontname": "Times bold"}


with Diagram("terraform-aws-infrastructure-live", graph_attr=common_attr):
    validator = LambdaFunction("2. Validate", labelloc="t", **common_attr)
    receiver = LambdaFunction("3. Receiver", **common_attr)
    create_deploy_stack = Fargate("6. Create Deploy Stack", **common_attr)

    APIGateway("1. Webhook Payload", **common_attr) >> validator
    validator >> receiver
    (
        receiver
        >> Edge(label="Open", color="cornflowerblue", style="bold", **common_attr)
        >> [
            SystemsManagerParameterStore("4. Merge Lock", **common_attr),
            Fargate("5. PR Plan", **common_attr),
        ]
    )
    (
        receiver
        >> Edge(label="Merged", color="chartreuse3", style="bold", **common_attr)
        >> create_deploy_stack
    )

    with Cluster("Deployment Flow", graph_attr=common_attr):
        trigger_sf = LambdaFunction(
            "7. Trigger Step Function", labelloc="t", **common_attr
        )
        eventbridge = Eventbridge("12. Finished Execution", labelloc="t", **common_attr)
        sf = StepFunctions(**common_attr)
        create_deploy_stack >> trigger_sf >> sf

        with Cluster("Step Function Execution", graph_attr=common_attr):
            plan = Fargate("8. Plan", **common_attr)
            request = LambdaFunction("9. Approval Request", labelloc="t", **common_attr)
            email = SimpleEmailServiceSesEmail()
            response = LambdaFunction("10. Approval Response", **common_attr)
            apply = Fargate("11. Apply", labelloc="t", **common_attr)

            sf >> [plan, eventbridge]
            eventbridge >> trigger_sf

            plan >> request >> email >> response >> apply

    Aurora("MetaDB", **common_attr) - [create_deploy_stack, trigger_sf, response, apply]
