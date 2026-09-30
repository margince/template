from diagrams import Diagram, Cluster, Edge
from diagrams.azure.compute import Disks
from diagrams.azure.network import PublicIpAddresses
from diagrams.azure.security import KeyVaults
from diagrams.azure.storage import RecoveryServicesVaults
from diagrams.azure.identity import AppRegistrations
from diagrams.onprem.client import Users
from diagrams.onprem.container import Docker
from diagrams.onprem.network import Nginx
from diagrams.onprem.database import Postgresql
from diagrams.onprem.inmemory import Redis
from diagrams.generic.compute import Rack

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.4",
    "splines": "spline",
}

with Diagram(
    "Margince on Azure — light",
    filename="azure-light-architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    outformat="png",
):
    users = Users("your users")
    operator = Users("operator\n(SSH, ssh_allowed_cidrs)")

    pip = PublicIpAddresses("Static public IP\n(fixed egress too)")

    with Cluster("VNet · one subnet"):
        with Cluster("VM Standard_B2ms (Ubuntu 24.04)"):
            caddy = Rack("Caddy :80/:443\nauto HTTPS (Let's Encrypt)")
            nginx = Nginx("nginx\nrouting + auth rate limits")
            with Cluster("Docker Compose"):
                web = Docker("web (SPA)")
                api = Docker("api :8080")
                worker = Docker("worker")
                pg = Postgresql("PostgreSQL 16\ncontainer")
                redis = Redis("Redis 7.2\ncontainer")

            data = Disks("Managed data disk\n/var/lib/docker volumes")
            caddy >> nginx
            nginx >> Edge(label="SPA") >> web
            nginx >> Edge(label="/v1 /webhooks\n/oauth /mcp") >> api
            api >> pg
            api >> redis
            worker >> pg
            worker >> redis
            api >> Edge(style="dashed", color="gray60") >> data
            worker >> Edge(style="dashed", color="gray60") >> data
            pg >> Edge(style="dashed", color="gray60") >> data
            redis >> Edge(style="dashed", color="gray60") >> data

    kv = KeyVaults("Key Vault\nEntra secret, license\n(firewall: operator IPs)")
    rsv = RecoveryServicesVaults("Recovery Services vault\ndaily VM backup, 7 days")
    entra = AppRegistrations("Entra ID\napp registration")

    users >> Edge(label="HTTPS") >> pip >> caddy
    operator >> Edge(label=":22") >> pip
    operator >> Edge(style="dashed", color="gray60", label="deploy\n(make deploy)") >> api
    operator >> Edge(style="dashed", color="gray60") >> kv
    worker >> Edge(style="dotted", color="firebrick", label="VM backup") >> rsv
    users >> Edge(style="dashed", label="sign in") >> entra
