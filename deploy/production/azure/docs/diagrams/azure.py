from diagrams import Diagram, Cluster, Edge
from diagrams.azure.compute import ContainerApps, ContainerRegistries, VMLinux
from diagrams.azure.database import DatabaseForPostgresqlServers
from diagrams.azure.network import ApplicationGateway, PublicIpAddresses, PrivateEndpoint
from diagrams.azure.security import KeyVaults
from diagrams.azure.storage import StorageAccounts, AzureFileshares
from diagrams.azure.identity import AppRegistrations, EntraManagedIdentities
from diagrams.azure.analytics import LogAnalyticsWorkspaces
from diagrams.azure.integration import PowerPlatform
from diagrams.onprem.client import Users

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.4",
    "splines": "spline",
}

with Diagram(
    "Margince on Azure — standard",
    filename="azure-architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    outformat="png",
):
    users = Users("your users")

    with Cluster("Microsoft cloud services"):
        entra = AppRegistrations("Entra ID\napp registration\nConditional Access")
        mscloud = PowerPlatform("Microsoft Graph\n+ Dataverse")

    with Cluster("Your subscription · VNet"):
        pip = PublicIpAddresses("Public IP")
        with Cluster("edge"):
            agw = ApplicationGateway("Application Gateway WAF_v2\nTLS + WAF policy")

        with Cluster("Container Apps environment (internal)"):
            with Cluster("api app (VNet-only ingress)"):
                edge = ContainerApps("edge · nginx :8081\nSPA, auth rules")
                api = ContainerApps("cmd/api :8080")
            worker = ContainerApps("worker\nno ingress")
            redis = ContainerApps("redis app\ninternal TCP :6379")

        pg = DatabaseForPostgresqlServers("Postgres Flexible\n(VNet-integrated)")
        kv = KeyVaults("Key Vault")
        files = AzureFileshares("Azure Files\nconfig, attachments")
        acr = ContainerRegistries("Container Registry")
        nat = PublicIpAddresses("NAT Gateway\nfixed egress IP")
        jb = VMLinux("Jumpbox + Bastion\noptional")
        pe = PrivateEndpoint("Private endpoints\nKV, storage, ACR")

    ids = EntraManagedIdentities("Managed identities\napi, worker, redis,\nappgw, data-cmk")
    la = LogAnalyticsWorkspaces("Log Analytics\nlogs, metrics, alerts")

    users >> Edge(label="HTTPS") >> pip >> agw
    users >> Edge(style="dashed", label="sign in") >> entra
    agw >> Edge(label="HTTPS, app FQDN as Host") >> edge
    agw >> Edge(style="dashed", color="gray60", label="public-tls cert") >> kv
    edge >> Edge(label="localhost") >> api
    api >> Edge(label=":5432") >> pg
    worker >> Edge(label=":5432") >> pg
    api >> Edge(label=":6379") >> redis
    worker >> Edge(label=":6379") >> redis

    for svc in (api, worker):
        svc >> Edge(style="dashed", color="gray60") >> files
        svc >> Edge(style="dashed", color="gray60") >> pe
    pe >> Edge(style="dashed", color="gray60") >> kv
    pe >> Edge(style="dashed", color="gray60") >> files
    pe >> Edge(style="dashed", color="gray60") >> acr
    acr >> Edge(style="dashed", color="gray60", label="image pull") >> worker

    api >> nat
    worker >> nat
    nat >> Edge(label="egress") >> mscloud
    jb >> Edge(style="dashed", color="gray60") >> pg
    jb >> Edge(style="dashed", color="gray60") >> acr

    for svc in (edge, api, worker, redis):
        svc >> Edge(style="dotted", color="gray60") >> ids
    agw >> Edge(style="dotted", color="gray60") >> ids
    api >> Edge(style="dashed", color="gray60") >> la
