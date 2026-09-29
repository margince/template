from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import ECS, ECR, Fargate
from diagrams.aws.database import RDSPostgresqlInstance, ElasticacheForRedis
from diagrams.aws.network import ALB, Route53, NATGateway, VPC
from diagrams.aws.security import WAF, KMS, SecretsManager
from diagrams.aws.storage import S3, EFS
from diagrams.aws.management import Cloudwatch
from diagrams.onprem.client import Users

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.4",
    "splines": "spline",
}

with Diagram(
    "Margince on AWS — full stack",
    filename="aws-architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    outformat="png",
):
    users = Users("your users")
    dns = Route53("Route 53\n(DNS, optional)")

    with Cluster("VPC"):
        with Cluster("Public subnets"):
            waf = WAF("WAF")
            alb = ALB("Application\nLoad Balancer")
            nat = NATGateway("NAT Gateway")
            waf >> Edge(style="dashed", label="attached") >> alb

        with Cluster("Private subnets"):
            with Cluster("ECS Fargate cluster"):
                api = Fargate("api service")
                worker = Fargate("worker service")
                web = Fargate("web service")

            rds = RDSPostgresqlInstance("RDS PostgreSQL\n(Multi-AZ)")
            cache = ElasticacheForRedis("ElastiCache\nRedis")

    ecr = ECR("ECR\n(3 repos)")
    efs = EFS("EFS\n(shared config)")
    kms = KMS("Customer-managed\nKMS key")
    secrets = SecretsManager("Secrets\nManager")
    s3 = S3("S3\nblobstore")
    logs = Cloudwatch("CloudWatch\nLogs")

    users >> Edge(label="HTTPS") >> dns >> alb
    alb >> Edge(label="/v1*, /webhooks/*, /oauth/*") >> api
    alb >> Edge(label="everything else") >> web
    nat >> Edge(style="dashed", label="egress for\nprivate subnets") >> alb

    for svc in (api, worker, web):
        svc >> Edge(label=":5432") >> rds
    for svc in (api, worker):
        svc >> Edge(label=":6379") >> cache
    for svc in (api, worker, web):
        svc >> Edge(style="dashed", color="gray60") >> ecr
    for svc in (api, worker):
        svc >> Edge(style="dashed", color="gray60") >> efs
    for svc in (api, worker):
        svc >> Edge(style="dashed", color="gray60") >> secrets
    for svc in (api, worker):
        svc >> Edge(style="dashed", color="gray60") >> s3
    for svc in (api, worker, web):
        svc >> Edge(style="dashed", color="gray60") >> logs

    for resource in (rds, cache, efs, secrets, s3):
        kms >> Edge(style="dotted", color="firebrick") >> resource
