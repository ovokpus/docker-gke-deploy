# Configure Secure RDP using a Windows Bastion Host

## Summary

This playbook describes how to deploy a secure Windows environment in Google Cloud using a bastion host and a completely isolated production server, explaining each concept and command in detail for clarity and reproducibility. ([cloud.google.com][1], [cloudskillsboost.google][2]) It covers creating a custom VPC network and subnet (“securenetwork”), configuring firewall rules for RDP access, launching two Windows Server 2016 VMs each with two network interfaces (one in the custom subnet and one in the default VPC) to enforce network isolation, setting up user credentials via `gcloud compute reset-windows-password`, connecting through RDP from your local machine to the bastion host and then to the secure server, and finally installing Internet Information Services (IIS) on the secure server using Server Manager. ([cloud.google.com][3], [cloud.google.com][4]) Each step includes conceptual explanations—such as why multiple NICs are needed and how internal-only connectivity enhances security—and is backed by authoritative sources. ([cloud.google.com][5], [cloud.google.com][6])

---

## Prerequisites and Concepts Overview

### Google Cloud Project and IAM Permissions

You must have an active Google Cloud project with sufficient quota to create VMs, networks, and firewall rules. ([cloud.google.com][1], [cloud.google.com][6]) You also need the “Compute Instance Admin (v1)” role (`roles/compute.instanceAdmin.v1`) or equivalent permissions to create networks, subnets, firewall rules, and Windows VMs with multiple network interfaces. ([cloud.google.com][7], [cloud.google.com][3])

### Custom-Mode VPC Networks

A custom-mode VPC network allows you to define specific subnets in designated regions instead of relying on auto-created subnets. ([cloud.google.com][1]) Custom-mode is critical here because we want `securenetwork` to be isolated and only host the internal-only interfaces for our secure server and bastion host. ([cloud.google.com][8], [cloud.google.com][9])

### Multiple Network Interfaces (NICs)

Attaching multiple NICs to a VM lets it participate in different VPCs simultaneously. ([cloud.google.com][3], [cloud.google.com][5]) In this playbook, each VM has:

- **A custom-network NIC** (in `securenetwork`) to isolate production traffic.
- **A default-network NIC** (in the default VPC) to allow connectivity with the existing monitoring system running in the default network.

Each interface must attach to a different VPC—Google Cloud does not allow two NICs on the same VM to reside in the same VPC. ([cloud.google.com][3], [cloud.google.com][10])

### Bastion Host and RDP Traffic Flow

A bastion host (also called a jump box) is a hardened VM that exposes only the necessary admin port—in our case, RDP (TCP 3389)—to the internet. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11]) From your local machine, you RDP to the public IP of `vm-bastionhost`, then from inside that RDP session you initiate another RDP connection to the private IP of `vm-securehost`. ([cloud.google.com][4], [cloud.google.com][1]) This two-hop model prevents direct internet exposure of `vm-securehost`, reducing the attack surface. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])

### Windows Server 2016 and IIS

Windows Server 2016 (with Desktop Experience) includes Server Manager, which is used to install Windows roles and features such as IIS. ([learn.microsoft.com][12], [learn.microsoft.com][13]) Internet Information Services (IIS) is a web server role you will install on `vm-securehost` to host applications internally. ([learn.microsoft.com][12], [dev.to][14])

---

## Task 1: Create the Secure VPC Network

### 1.1 Create Custom-Mode VPC called `securenetwork`

Creating a custom-mode VPC ensures you have full control over subnet ranges and region placement. ([cloud.google.com][1], [cloud.google.com][8])

```bash
gcloud compute networks create securenetwork \
    --subnet-mode=custom
```

- `--subnet-mode=custom` designates that you will manually define any subnets for this VPC rather than using auto-mode. ([cloud.google.com][1], [cloud.google.com][8])
- The resulting network is empty until subnets are created. ([cloud.google.com][1], [cloud.google.com][15])

### 1.2 Create a Subnet in `europe-west1`

Select a CIDR range that does not overlap with other VPCs (for example, `10.10.0.0/24`), ensuring isolation. ([cloud.google.com][8], [cloud.google.com][9])

```bash
gcloud compute networks subnets create securenetwork-subnet \
    --network=securenetwork \
    --region=europe-west1 \
    --range=10.10.0.0/24
```

- This command attaches a subnet named `securenetwork-subnet` in region `europe-west1`. ([cloud.google.com][1], [cloud.google.com][8])
- The `/24` range supports up to 256 internal IPs, with 4 reserved addresses per subnet. ([cloud.google.com][8], [cloud.google.com][9])

### 1.3 Define a Bastion Host Network Tag

We will tag the bastion host VM with `rdp-bastion` so that only it is allowed to receive RDP traffic from the internet. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])

### 1.4 Create a Firewall Rule to Allow RDP to the Bastion Host

A firewall rule scoped to `securenetwork` will permit inbound TCP 3389 from any IP (`0.0.0.0/0`) but only to VMs tagged `rdp-bastion`. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])

```bash
gcloud compute firewall-rules create allow-rdp-bastion \
    --network=securenetwork \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:3389 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=rdp-bastion
```

- `--direction=INGRESS` specifies that this rule controls incoming traffic. ([cloudskillsboost.google][2], [cloud.google.com][15])
- `--rules=tcp:3389` limits the rule to RDP port only. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])
- `--target-tags=rdp-bastion` ensures only VMs with that tag can receive RDP. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])

---

## Task 2: Deploy Windows Instances and Configure User Passwords

### 2.1 Deploy the Secure Server (`vm-securehost`)

We will create a Windows Server 2016 VM with two network interfaces:

- **NIC0** → `securenetwork-subnet` (internal-only, no external IP)
- **NIC1** → `default` VPC subnet (internal-only, no external IP)

Each NIC connects to a different VPC, enforcing network segmentation. ([cloud.google.com][3], [cloud.google.com][10]) The `no-address` flag on both NICs prevents the assignment of ephemeral external IPs, ensuring `vm-securehost` cannot be reached from the internet. ([cloud.google.com][3], [cloud.google.com][5])

```bash
gcloud compute instances create vm-securehost \
    --zone=europe-west1-d \
    --machine-type=n1-standard-2 \
    --image-family=windows-server-2016-dc \
    --image-project=windows-cloud \
    --network-interface=network=securenetwork,subnet=securenetwork-subnet,no-address \
    --network-interface=network=default,subnet=default,no-address
```

- `--machine-type=n1-standard-2` selects a machine with 2 vCPUs and 7.5 GB RAM, suitable for running IIS in production. ([cloud.google.com][3], [cloud.google.com][6])
- `--image-family=windows-server-2016-dc` and `--image-project=windows-cloud` instruct GCP to use the latest Windows Server 2016 Datacenter image. ([cloud.google.com][3], [cloud.google.com][6])

#### Concepts Explained

- **Multiple NICs and VPC Isolation**: By attaching `vm-securehost` to both `securenetwork` and the default VPC, it can serve internal application traffic (in `securenetwork`) while still sending monitoring data back through the default network. ([cloud.google.com][5], [cloud.google.com][3])
- **Internal-Only Connectivity**: Neither NIC has an external IP assigned, so `vm-securehost` is protected from direct internet access, reducing attack surface. ([cloud.google.com][3], [cloud.google.com][10])

### 2.2 Deploy the Bastion Host (`vm-bastionhost`)

Similarly, we create a second Windows Server 2016 VM with two NICs:

- **NIC0** → `securenetwork-subnet` (ephemeral external IP for RDP, tagged `rdp-bastion`)
- **NIC1** → `default` VPC subnet (internal-only, no external IP)

```bash
gcloud compute instances create vm-bastionhost \
    --zone=europe-west1-d \
    --machine-type=n1-standard-2 \
    --image-family=windows-server-2016-dc \
    --image-project=windows-cloud \
    --tags=rdp-bastion \
    --network-interface=network=securenetwork,subnet=securenetwork-subnet \
    --network-interface=network=default,subnet=default,no-address
```

- Omitting `no-address` on the first interface gives the bastion host an ephemeral external IP automatically. ([cloud.google.com][3], [cloud.google.com][5])
- `--tags=rdp-bastion` applies the firewall rule created earlier, allowing RDP from the internet solely to this VM. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])

#### Concepts Explained

- **Bastion Host Role**: The bastion is the only VM reachable via RDP from the internet (via its external IP). ([cloudskillsboost.google][2], [cloud.google.com][4])
- **Network Tag Usage**: By tagging the VM `rdp-bastion`, we scoped RDP access to only that host. Without this tag, other VMs (including the secure host) would not accept direct RDP traffic. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])
- **Second NIC to Default Network**: This allows the bastion host to communicate with monitoring tools in the default VPC as needed. ([cloud.google.com][3], [cloud.google.com][5])

### 2.3 Verify Network Interfaces

After creation, confirm that each VM has two interfaces by describing them:

```bash
gcloud compute instances describe vm-securehost \
    --zone=europe-west1-d \
    --format="json(networkInterfaces)"
gcloud compute instances describe vm-bastionhost \
    --zone=europe-west1-d \
    --format="json(networkInterfaces)"
```

- `vm-securehost` should show `nic0` (network=`securenetwork`, no external IP) and `nic1` (network=`default`, no external IP). ([cloud.google.com][3], [cloud.google.com][10])
- `vm-bastionhost` should show `nic0` (network=`securenetwork`, external IP plus internal IP) and `nic1` (network=`default`, no external IP) ([cloud.google.com][3], [cloud.google.com][10])

### 2.4 Reset Windows Passwords for `app_admin`

Use `gcloud compute reset-windows-password` to create (or reset) a local user named `app_admin` on each VM and retrieve a generated password: ([cloud.google.com][16], [cloud.google.com][17])

```bash
gcloud compute reset-windows-password vm-bastionhost \
    --user app_admin \
    --zone europe-west1-d
```

- This command sends an RSA public key to the VM’s instance agent, which sets the password. ([cloud.google.com][18], [cloud.google.com][16])
- Copy the **Username** (app_admin) and **Password** returned; these will be used for RDP access. ([cloud.google.com][17], [cloud.google.com][16])

```bash
gcloud compute reset-windows-password vm-securehost \
    --user app_admin \
    --zone europe-west1-d
```

- Save the credentials for `vm-securehost` as well; they differ from the bastion host’s credentials. ([cloud.google.com][17], [cloud.google.com][16])

#### Concepts Explained

- **VMGuest Agent and Password Reset**: The GCP VM guest agent on Windows listens for `reset-windows-password` requests, creates or updates the specified user, and returns a secure password. ([cloud.google.com][18], [cloud.google.com][17])
- **Security Best Practice**: Resetting passwords via GCP ensures no weak or default passwords remain. ([cloud.google.com][18], [cloud.google.com][17])

---

## Task 3: Connect to the Secure Host and Configure IIS

### 3.1 RDP from Local Machine to `vm-bastionhost`

1. Open **Remote Desktop Connection** (`mstsc.exe`) on your local Windows machine. ([cloud.google.com][4], [cloud.google.com][1])
2. In the “Computer” field, enter the **external IP** of `vm-bastionhost` (visible in the GCP Console VM instances page). ([cloud.google.com][4], [cloud.google.com][1])
3. Provide the **Username** (`app_admin`) and **Password** retrieved from `reset-windows-password`. ([cloud.google.com][16], [cloud.google.com][17])
4. Click **Connect**; you are now in an RDP session on the bastion host. ([cloud.google.com][4], [cloud.google.com][1])

#### Concepts Explained

- **RDP (Remote Desktop Protocol)**: RDP uses TCP 3389; the bastion’s firewall rule limits access to this port only. ([cloud.google.com][4], [cloudskillsboost.google][2])
- **Two-Hop Connection**: The bastion acts as a pivot point—once inside, you must initiate RDP to the secure host’s private IP. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])

### 3.2 RDP from Bastion Host to `vm-securehost`

1. On `vm-bastionhost`’s desktop, open **Remote Desktop Connection** (`Start → Run → mstsc.exe`). ([cloud.google.com][4], [cloud.google.com][16])
2. Enter the **internal IP** of `vm-securehost` (found in the GCP Console VM instances page). ([cloud.google.com][16], [cloud.google.com][3])
3. Authenticate using the **Username** (`app_admin`) and **Password** from `reset-windows-password vm-securehost`. ([cloud.google.com][16], [cloud.google.com][17])
4. Click **Connect** to log into `vm-securehost`. ([cloud.google.com][4], [cloud.google.com][3])

#### Concepts Explained

- **Internal Network Reachability**: Because both VMs are in `securenetwork`, they can see each other’s private IP addresses (e.g., 10.10.0.x). ([cloud.google.com][5], [cloud.google.com][3])
- **Security Isolation**: There is no direct path from the internet to `vm-securehost`, only via the bastion. ([cloudskillsboost.google][2], [googlecloudcommunity.com][11])

### 3.3 Install Internet Information Services (IIS) on `vm-securehost`

1. Once logged into `vm-securehost`’s desktop, **Server Manager** may auto-launch; otherwise, click **Start** and open **Server Manager**. ([learn.microsoft.com][12], [learn.microsoft.com][13])
2. In **Server Manager**, click the **Manage** menu (top-right) and select **Add Roles and Features**. ([learn.microsoft.com][12], [dev.to][14])
3. On the **Before you Begin** page of the wizard, click **Next**. ([learn.microsoft.com][12], [dev.to][14])
4. On **Installation Type**, choose **Role-based or feature-based installation** and click **Next**. ([learn.microsoft.com][12], [dev.to][14])
5. On **Server Selection**, ensure your local server (`vm-securehost`) is selected and click **Next**. ([learn.microsoft.com][12], [dev.to][14])
6. On **Server Roles**, check **Web Server (IIS)**. When prompted to add required features, click **Add Features**, then click **Next**. ([learn.microsoft.com][12], [learn.microsoft.com][13])
7. On **Features**, accept defaults and click **Next**. ([learn.microsoft.com][12], [dev.to][14])
8. On the **Web Server Role (IIS)** page, click **Next** (overview of IIS). ([learn.microsoft.com][12], [dev.to][14])
9. On **Role Services**, leave defaults (Common HTTP Features, Security, Performance, etc.), then click **Next**. ([learn.microsoft.com][12], [learn.microsoft.com][13])
10. On **Confirmation**, optionally check **Restart the destination server automatically if required**, then click **Install**. ([learn.microsoft.com][12], [learn.microsoft.com][13])
11. Wait for installation to complete (progress should reach 100%), then click **Close**. ([learn.microsoft.com][12], [learn.microsoft.com][13])

#### Concepts Explained

- **Server Manager Role-Based Installation**: This wizard simplifies adding or removing Windows Server roles. ([learn.microsoft.com][12], [learn.microsoft.com][13])
- **IIS Components**: The default Role Services install the core web server and necessary HTTP features; additional modules like ASP.NET can be added if needed. ([learn.microsoft.com][12], [learn.microsoft.com][13])

### 3.4 Verify IIS Is Running

1. Open a web browser on `vm-securehost` (e.g., Edge or Internet Explorer). ([learn.microsoft.com][12], [cloud.google.com][4])
2. Navigate to `http://localhost`. ([learn.microsoft.com][12], [learn.microsoft.com][13])
3. You should see the default **IIS Welcome** page confirming that the web server is active. ([learn.microsoft.com][12], [learn.microsoft.com][13])

#### Concepts Explained

- **Localhost URI**: Because no DNS or external IP is configured for `vm-securehost`, you verify IIS by browsing to `localhost` from the VM itself over the loopback interface (127.0.0.1). ([learn.microsoft.com][12], [learn.microsoft.com][13])
- **IIS Default Page**: The “Welcome to IIS” page verifies that the service is installed, started, and listening on port 80 by default. ([learn.microsoft.com][12], [learn.microsoft.com][13])

---

## Final Verification and Cleanup

### 4.1 Verify RDP Connectivity Flow

1. From your local machine, ensure you can only RDP to `vm-bastionhost`’s external IP. ([cloud.google.com][4], [cloudskillsboost.google][2])
2. From `vm-bastionhost`, verify you can RDP to `vm-securehost`’s private IP. ([cloud.google.com][4], [cloudskillsboost.google][2])
3. Confirm that you cannot RDP directly to `vm-securehost` from your local machine (no external IP). ([cloud.google.com][3], [cloudskillsboost.google][2])

### 4.2 Confirm IIS Functionality

1. Ensure the IIS welcome page is visible at `http://localhost` on `vm-securehost`. ([learn.microsoft.com][12], [learn.microsoft.com][13])
2. Optionally deploy a sample HTML file or ASP.NET application to test connectivity via `vm-bastionhost → vm-securehost` if you have internal tools or browser installed on the bastion. ([learn.microsoft.com][12], [dev.to][14])

### 4.3 (Optional) Clean Up Resources

If this environment is only for testing or a short-lived project, delete the VMs, firewall rule, subnet, and VPC to avoid charges: ([cloud.google.com][1], [cloud.google.com][15])

```bash
gcloud compute instances delete vm-bastionhost vm-securehost --zone=europe-west1-d --quiet
gcloud compute firewall-rules delete allow-rdp-bastion --quiet
gcloud compute networks subnets delete securenetwork-subnet --region=europe-west1 --quiet
gcloud compute networks delete securenetwork --quiet
```

---

## Conclusion

Following this playbook, you will have successfully built a secure Windows environment in Google Cloud: a bastion host accessible only via RDP, a production server isolated from the internet with IIS installed, and separation of management (default network) from application traffic (custom VPC). Each step’s concepts—custom-mode VPCs, multiple NICs, network tags, bastion-host security, and IIS role installation—ensures an enterprise-grade, segmented architecture. ([cloud.google.com][1], [cloud.google.com][5], [cloudskillsboost.google][2])

---

**Citations**

1. “Quickstart: Create and manage VPC networks” — cloud.google.com ([cloud.google.com][1])
2. “Create VMs with multiple network interfaces” — cloud.google.com ([cloud.google.com][3])
3. “gcloud compute reset-windows-password” — cloud.google.com ([cloud.google.com][16])
4. “Connect to Windows VMs using RDP” — cloud.google.com ([cloud.google.com][4])
5. “Install or Uninstall Roles, Role Services, or Features” — learn.microsoft.com ([learn.microsoft.com][12])
6. “Networking overview for VMs” — cloud.google.com ([cloud.google.com][5])
7. “Manage accounts and credentials on Windows VMs” — cloud.google.com ([cloud.google.com][17])
8. “Configure Secure RDP using a Windows Bastion Host: Challenge Lab” — cloudskillsboost.google ([cloudskillsboost.google][2])
9. “Installing the Web Server Role” — learn.microsoft.com ([learn.microsoft.com][13])
10. “Create and use internal ranges” — cloud.google.com ([cloud.google.com][9])
11. “gcloud compute instances create | Google Cloud CLI Documentation” — cloud.google.com ([cloud.google.com][19])
12. “Automating Windows password generation” — cloud.google.com ([cloud.google.com][18])
13. “Re: Configure Secure RDP using a Windows Bastion Host” — googlecloudcommunity.com ([googlecloudcommunity.com][11])
14. “Configure Windows Roles and Features on Windows Server 2016” — help.salesforce.com ([help.salesforce.com][20])
15. “Manage VPC resources by using custom organization policies” — cloud.google.com ([cloud.google.com][21])
16. “Create an instance in a specific subnet” — cloud.google.com ([cloud.google.com][10])
17. “Reboot or reset a Compute Engine instance” — cloud.google.com ([cloud.google.com][7])
18. “juaragcp/labs/gsp303_configure-secure-rdp-using-a-windows-bastion-host/script.sh” — GitHub ([github.com][22])
19. “Enabling the IIS web server in Windows” — help.claris.com ([help.claris.com][23])
20. “Create and manage Windows Server VMs” — cloud.google.com ([cloud.google.com][6])
21. “Configure a bastion host | Distributed Cloud connected” — cloud.google.com ([cloud.google.com][24])
22. “How to Install IIS on Windows Server” — dev.to ([dev.to][14])
23. “gcloud compute networks create | Google Cloud CLI Documentation” — cloud.google.com ([cloud.google.com][15])
24. “Create and start a Compute Engine instance” — cloud.google.com ([cloud.google.com][25])

[1]: https://cloud.google.com/vpc/docs/create-modify-vpc-networks?utm_source=chatgpt.com "Quickstart: Create and manage VPC networks - Google Cloud"
[2]: https://www.cloudskillsboost.google/focuses/1737?parent=catalog&utm_source=chatgpt.com "Configure Secure RDP using a Windows Bastion Host: Challenge Lab"
[3]: https://cloud.google.com/vpc/docs/create-use-multiple-interfaces?utm_source=chatgpt.com "Create VMs with multiple network interfaces | VPC - Google Cloud"
[4]: https://cloud.google.com/compute/docs/instances/connecting-to-windows?utm_source=chatgpt.com "Connect to Windows VMs using RDP - Google Cloud"
[5]: https://cloud.google.com/compute/docs/networking/network-overview?utm_source=chatgpt.com "Networking overview for VMs - Compute Engine - Google Cloud"
[6]: https://cloud.google.com/compute/docs/instances/windows/creating-managing-windows-instances?utm_source=chatgpt.com "Create and manage Windows Server VMs - Google Cloud"
[7]: https://cloud.google.com/compute/docs/instances/reset-instance?utm_source=chatgpt.com "Reboot or reset a Compute Engine instance - Google Cloud"
[8]: https://cloud.google.com/vpc/docs/vpc?utm_source=chatgpt.com "VPC networks | Google Cloud"
[9]: https://cloud.google.com/vpc/docs/create-use-internal-ranges?utm_source=chatgpt.com "Create and use internal ranges | VPC - Google Cloud"
[10]: https://cloud.google.com/compute/docs/instances/create-vm-specific-subnet?utm_source=chatgpt.com "Create an instance in a specific subnet - Google Cloud"
[11]: https://www.googlecloudcommunity.com/gc/Learning-Forums/Configure-Secure-RDP-using-a-Windows-Bastion-Host-Challenge-Lab/m-p/741073?utm_source=chatgpt.com "Re: Configure Secure RDP using a Windows Bastion Host"
[12]: https://learn.microsoft.com/en-us/windows-server/administration/server-manager/install-or-uninstall-roles-role-services-or-features?utm_source=chatgpt.com "Install or Uninstall Roles, Role Services, or Features | Microsoft Learn"
[13]: https://learn.microsoft.com/en-us/iis/web-hosting/web-server-for-shared-hosting/installing-the-web-server-role?utm_source=chatgpt.com "Installing the Web Server Role | Microsoft Learn"
[14]: https://dev.to/s3cloudhub/how-to-install-iis-on-windows-server-2e9l?utm_source=chatgpt.com "How to Install IIS on Windows Server - DEV Community"
[15]: https://cloud.google.com/sdk/gcloud/reference/compute/networks/create?utm_source=chatgpt.com "gcloud compute networks create | Google Cloud CLI Documentation"
[16]: https://cloud.google.com/sdk/gcloud/reference/compute/reset-windows-password?utm_source=chatgpt.com "gcloud compute reset-windows-password"
[17]: https://cloud.google.com/compute/docs/instances/windows/generating-credentials?utm_source=chatgpt.com "Manage accounts and credentials on Windows VMs - Google Cloud"
[18]: https://cloud.google.com/compute/docs/instances/windows/automate-pw-generation?utm_source=chatgpt.com "Automating Windows password generation - Google Cloud"
[19]: https://cloud.google.com/sdk/gcloud/reference/compute/instances/create?utm_source=chatgpt.com "gcloud compute instances create | Google Cloud CLI Documentation"
[20]: https://help.salesforce.com/s/articleView?id=ind.cg_modeler_ibe_config_win_roles_2016_2019.htm&language=en_US&type=5&utm_source=chatgpt.com "Configure Windows Roles and Features on Windows Server 2016 ..."
[21]: https://cloud.google.com/vpc/docs/custom-constraints?utm_source=chatgpt.com "Manage VPC resources by using custom organization policies"
[22]: https://github.com/elmoallistair/qwiklabs/blob/master/labs/gsp303_configure-secure-rdp-using-a-windows-bastion-host/script.sh?utm_source=chatgpt.com "juaragcp/labs/gsp303_configure-secure-rdp-using-a ... - GitHub"
[23]: https://help.claris.com/en/server-installation-configuration-guide/content/enabling-iis-windows.html?utm_source=chatgpt.com "Enabling the IIS web server in Windows - Claris Help Center"
[24]: https://cloud.google.com/distributed-cloud/edge/latest/docs/bastion?utm_source=chatgpt.com "Configure a bastion host | Distributed Cloud connected"
[25]: https://cloud.google.com/compute/docs/instances/create-start-instance?utm_source=chatgpt.com "Create and start a Compute Engine instance - Google Cloud"
