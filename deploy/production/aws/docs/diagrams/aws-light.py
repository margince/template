from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.network import CloudFront, VPC
from diagrams.aws.security import CertificateManager, WAF, SecretsManager
from diagrams.aws.storage import S3
from diagrams.aws.management import Cloudwatch
from diagrams.onprem.client import Users

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.4",
    "splines": "spline",
}

with Diagram(
    "Margince on AWS — light",
    filename="aws-light-architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    outformat="png",
):
    users = Users("your users")

    with Cluster("CloudFront (public entry point)"):
        acm = CertificateManager("ACM cert\n(us-east-1)")
        waf = WAF("WAF\n(optional)")
        cf = CloudFront("CloudFront\ndistribution")
        acm >> Edge(style="dashed", label="TLS cert") >> cf
        waf >> Edge(style="dashed", label="optional") >> cf

    with Cluster("VPC"):
        with Cluster("Public subnet"):
            edge = EC2("edge\nnginx + frontend/dist")
            app = EC2("app\napi + valkey")
            worker = EC2("worker\nmargince-worker")

        with Cluster("Private subnets"):
            rds = RDSPostgresqlInstance("RDS PostgreSQL\n(managed)")

    s3 = S3("S3\nblobstore + build\nsource/binaries")
    secrets = SecretsManager("Secrets\nManager")
    logs = Cloudwatch("CloudWatch\nLogs")

    users >> Edge(label="HTTPS") >> cf
    cf >> Edge(label="HTTP + shared secret\n(SG: CloudFront IPs only)") >> edge
    edge >> Edge(label=":8080") >> app
    worker >> Edge(label="valkey :6379\n(AUTH token)") >> app
    app >> Edge(label=":5432") >> rds
    worker >> Edge(label=":5432") >> rds

    for instance in (edge, app, worker):
        instance >> Edge(style="dashed", color="gray40", label="source/binaries") >> s3
    for instance in (app, worker):
        instance >> Edge(style="dashed", color="gray40") >> secrets
    for instance in (edge, app, worker):
        instance >> Edge(style="dashed", color="gray40") >> logs
