from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import ECR, Fargate
from diagrams.aws.database import RDSPostgresqlInstance, ElasticacheForRedis
from diagrams.aws.network import ALB, NATGateway, Endpoint
from diagrams.aws.security import WAF, KMS, CertificateManager
from diagrams.aws.storage import S3, EFS
from diagrams.aws.management import Cloudwatch, SystemsManager
from diagrams.aws.integration import SNS
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
    dns = Users("your DNS provider\n(A record to the ALB)")

    with Cluster("VPC"):
        with Cluster("Public subnets"):
            waf = WAF("WAF web ACL")
            acm = CertificateManager("ACM cert\n(var.acm_certificate_arn)")
            alb = ALB("Application\nLoad Balancer")
            nat = NATGateway("NAT Gateway")
            waf >> Edge(style="dashed", label="attached") >> alb
            acm >> Edge(style="dashed", label="TLS") >> alb

        with Cluster("Private subnets"):
            with Cluster("ECS Fargate cluster"):
                api = Fargate("api service")
                worker = Fargate("worker service")
                web = Fargate("web service")

            rds = RDSPostgresqlInstance("RDS PostgreSQL\n(Multi-AZ)")
            cache = ElasticacheForRedis("ElastiCache\nRedis")
            vpce = Endpoint("VPC endpoints\necr.api ecr.dkr ssm\nkms logs + S3 gateway")

    ecr = ECR("ECR\n(3 repos)")
    efs = EFS("EFS\n(shared config)")
    kms = KMS("Customer-managed\nKMS key")
    secrets = SystemsManager("SSM Parameter Store\nSecureStrings")
    s3 = S3("S3\nblobstore")
    s3logs = S3("S3\nALB + blobstore logs")
    logs = Cloudwatch("CloudWatch\nLogs + alarms")
    alerts = SNS("SNS alerts\nemail")

    users >> Edge(label="HTTPS") >> dns >> alb
    alb >> Edge(label="/v1* /healthz /readyz\n/webhooks/* /oauth/*\n/mcp* /.well-known/*") >> api
    alb >> Edge(label="everything else") >> web
    nat >> Edge(style="dashed", label="egress for\nprivate subnets") >> alb

    for svc in (api, worker, web):
        svc >> Edge(label=":5432") >> rds
    for svc in (api, worker):
        svc >> Edge(label=":6379") >> cache
    for svc in (api, worker, web):
        svc >> Edge(style="dashed", color="gray60") >> vpce
    for svc in (api, worker):
        svc >> Edge(style="dashed", color="gray60") >> efs
    for svc in (api, worker):
        svc >> Edge(style="dashed", color="gray60") >> secrets
    for svc in (api, worker):
        svc >> Edge(style="dashed", color="gray60") >> s3
    for svc in (api, worker, web):
        svc >> Edge(style="dashed", color="gray60") >> logs

    vpce >> Edge(style="dashed", color="gray60") >> ecr
    alb >> Edge(style="dashed", color="gray60", label="access logs") >> s3logs
    s3 >> Edge(style="dashed", color="gray60", label="access logs") >> s3logs
    logs >> Edge(style="dashed", color="gray60") >> alerts

    for resource in (rds, cache, efs, secrets, s3):
        kms >> Edge(style="dotted", color="firebrick") >> resource
