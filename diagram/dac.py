from diagrams import Cluster, Diagram, Edge
from diagrams.aws.database import Aurora
from diagrams.aws.compute import LambdaFunction, Fargate
from diagrams.aws.integration import StepFunctions
from diagrams.aws.integration import Eventbridge
from diagrams.aws.management import SystemsManagerParameterStore
from diagrams.aws.integration import SimpleNotificationServiceSnsTopic
from diagrams.custom import Custom

node_attr = {"fontsize": "25", "height": "10.6", "fontname": "Times bold"}

graph_attr = {
    "fontsize": "60",
    "compund": "True",
    "splines": "spline",
}

edge_attr = {
    "minlen": "2.0",
    "penwidth": "3.0",
    "concentrate": "true",
}

cluster_attr = {
    "fontsize": "40",
}

with Diagram(
    "terraform-aws-infrastructure-live",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    receiver = LambdaFunction("2. Receiver")
    create_deploy_stack = Fargate("5. Create Deploy Stack")

    receiver
    (
        Custom("1. GitHub Event", "./gh_icon.png")
        >> receiver
        >> Edge(
            label="Open",
            color="cornflowerblue",
            style="bold",
            fontsize="20",
            fontname="Times bold",
        )
        >> [
            SystemsManagerParameterStore("3. Merge Lock"),
            Fargate("4. PR Plan"),
        ]
    )
    (
        receiver
        >> Edge(
            label="Merged",
            color="chartreuse3",
            style="bold",
            fontsize="20",
            fontname="Times bold",
        )
        >> create_deploy_stack
    )

    with Cluster("Deployment Flow", graph_attr=cluster_attr):
        trigger_sf = LambdaFunction("6. Trigger Step Function", labelloc="t")
        eventbridge = Eventbridge("11. Finished Execution", labelloc="t")
        sf = StepFunctions()
        create_deploy_stack >> trigger_sf >> sf

        with Cluster("Step Function Execution", graph_attr=cluster_attr):
            plan = Fargate("7. Plan")
            request = SimpleNotificationServiceSnsTopic(
                "8. Approval Request", labelloc="t"
            )
            response = LambdaFunction("9. Approval Response")
            apply = Fargate("10. Apply", labelloc="t")

            sf >> [plan, eventbridge]
            eventbridge >> trigger_sf

            plan >> request >> response >> apply

    Aurora("MetaDB") - [create_deploy_stack, trigger_sf, response, apply]
