## Overview

This playbook guides you through deploying a Google Cloud Compute Engine instance that uses a **remote startup script** stored in a Cloud Storage bucket. Rather than embedding the script directly in the VM’s metadata, we’ll keep it in a bucket (`install-web.sh`), making it easier to iterate on and version-control your initialization logic. In the end, the VM will automatically install Apache on boot, and you’ll verify that HTTP traffic can reach it from the internet.

The high-level tasks are:

1. **Create a Cloud Storage bucket** to hold your startup scripts.
2. **Upload the `install-web.sh` script** into that bucket.
3. **Create a VM instance** in `us-central1-c` with metadata pointing to the remote script.
4. **Verify Apache** is serving over HTTP.

Throughout, we’ll explain why each concept matters and how the pieces fit together.

---

## Prerequisites

- You have a Google Cloud project with billing enabled.
- Your user (or service account) has permissions to create buckets, upload objects, and launch Compute Engine VMs.
- The Cloud SDK (`gcloud`) and `gsutil` are installed and authenticated, or you can use the Cloud Console UI.
- Basic familiarity with Linux shell commands and GCP Console is assumed.

---

## 1. Create a Cloud Storage Bucket

### Concepts Covered

- **Cloud Storage Buckets**: A bucket is a top-level container for storing objects (files). Buckets have a globally unique name and live in a chosen location (“region” or “multi-region”).
- **Regions vs. Zones**: Buckets are regional or multi-regional. We’ll pick `us-central1` so that our VM in `us-central1-c` can fetch the script with minimal latency and egress costs.
- **Naming Requirements**: Bucket names must be 3–63 characters, lowercase letters, numbers, and hyphens only, and globally unique across all GCP projects.

### Steps

You can create the bucket either via the GCP Console or the `gsutil` CLI. Pick your preferred method:

---

#### Option A: Cloud Console

1. Go to **Storage → Browser** in the Google Cloud Console.
2. Click **Create bucket**.
3. **Name** your bucket something unique, for example:

   ```
   my-startup-scripts-<your-unique-suffix>
   ```

   (Replace `<your-unique-suffix>` with a random string or your initials + date.)

4. For **Location**, choose **Region: us-central1**.
5. Keep the **Storage class** as **Standard** (default).
6. Leave **Access control** on **Uniform** (simplest IAM model).
7. Click **Create**.

You will now see `gs://my-startup-scripts-<your-suffix>/` in your bucket list.

---

#### Option B: CLI (gsutil)

If you like the command line, run:

```bash
# Ensure your project is set correctly:
gcloud config get-value project

# Create the bucket in us-central1 with the Standard class:
gsutil mb \
  -p "$(gcloud config get-value project)" \
  -l us-central1 \
  -c standard \
  gs://my-startup-scripts-<YOUR-UNIQUE-SUFFIX>/
```

- `mb` = “make bucket,”
- `-l us-central1` pins the bucket’s region,
- `-c standard` selects the standard storage class.

Verify the bucket exists:

```bash
gsutil ls
# You should see: gs://my-startup-scripts-<YOUR-UNIQUE-SUFFIX>/
```

---

## 2. Upload the `install-web.sh` Script

```bash

#!/bin/bash
apt-get update
apt-get install -y apache2
```

### Concepts Covered

- **Startup Scripts**: A shell script that runs automatically on VM first boot. By storing it in Cloud Storage, you can update it centrally without recreating VMs.
- **Public Source vs. Your Bucket**: Google provides a sample `install-web.sh` at `gs://spls/gsp301/install-web.sh`. We’ll copy that into our bucket so we can edit or version it later.

### Steps

Again, choose between the Cloud Console UI or `gsutil`:

---

#### Option A: Cloud Console

1. Download the sample script from:

   ```
   https://storage.googleapis.com/spls/gsp301/install-web.sh
   ```

   (Or simply upload it directly if you already have it.)

2. In the Console, go to **Storage → Browser**, then click on your bucket (`my-startup-scripts-<…>`).
3. Click **Upload files**, select `install-web.sh`, and click **Open**.
4. Wait for the “Upload complete” notification.

You should now see `install-web.sh` listed under your bucket’s objects.

---

#### Option B: CLI (gsutil)

To copy directly from Google’s public bucket:

```bash
BUCKET=gs://my-startup-scripts-<YOUR-UNIQUE-SUFFIX>/

# Copy the publicly-hosted script into your bucket:
gsutil cp gs://spls/gsp301/install-web.sh $BUCKET
```

Output will look like:

```
Copying gs://spls/gsp301/install-web.sh …
- [1 files][  2.4 KiB/  2.4 KiB] 100% Done
```

Verify:

```bash
gsutil ls $BUCKET
# Expected: gs://my-startup-scripts-<…>/install-web.sh
```

> **Tip**: You can edit `install-web.sh` in your bucket later if you need to customize the Apache installation steps, add SSL certificates, or embed configuration files.

---

## 3. Create a VM Instance with the Remote Startup Script

### Concepts Covered

1. **Compute Engine Instance**: A virtual machine running on Google’s infrastructure.
2. **Zone Selection**: We must launch in `us-central1-c` (per the challenge requirements).
3. **Machine Type**: For a simple Apache web server, `e2-micro` (low-cost) is sufficient.
4. **Tags & Firewall Rules**: To allow external HTTP (port 80), VMs must have a network tag (e.g., `http-server`) matched by a firewall rule that opens TCP:80.
5. **Metadata & `startup-script-url`**: Instead of embedding script text in the metadata key named `startup-script`, we point to a **URL** (`gs://…/install-web.sh`). Compute Engine fetches and runs this script at first boot.
6. **Apache Installation Flow**: The `install-web.sh` script typically does:

   ```bash
   #! /bin/bash
   apt-get update
   apt-get install -y apache2
   systemctl enable apache2
   systemctl start apache2
   echo "<h1>Deployed via remote startup script</h1>" > /var/www/html/index.html
   ```

   This installs Apache, ensures it starts on reboot, and writes a simple index page.

### Steps

#### A. Ensure an HTTP Firewall Rule Exists

Compute Engine uses network tags and firewall rules to allow or deny traffic:

1. **Check for an existing HTTP rule**
   By default, many projects already have a rule named `default-allow-http` or similar that opens TCP:80 to VMs with the `http-server` tag. To verify, run:

   ```bash
   gcloud compute firewall-rules list \
     --filter="name~'allow-http' AND direction=INGRESS" \
     --format="table(name,priority,network,sourceRanges,allowed)"
   ```

2. **Create the rule if needed**
   If nothing returns or if you prefer a custom rule:

   ```bash
   gcloud compute firewall-rules create allow-http \
     --description="Allow incoming HTTP (port 80)" \
     --direction=INGRESS \
     --action=ALLOW \
     --rules=tcp:80 \
     --target-tags=http-server
   ```

   - **`--target-tags=http-server`** means: only VMs tagged with `http-server` will have port 80 open.
   - **Default sourceRanges** for a public rule is `0.0.0.0/0` (any IPv4).

---

#### B. Create the VM: Cloud Console

1. In the Console, go to **Compute Engine → VM instances**.
2. Click **Create instance**.
3. **Name**: e.g. `apache-vm-remote`.
4. **Region & Zone**:

   - Region: `us-central1`
   - Zone: `us-central1-c` (required)

5. **Machine configuration**:

   - Machine type: `e2-micro`.

6. **Boot disk**:

   - Click **Change**, select **Debian 11 (bullseye)** (or Ubuntu if you prefer). Click **Select**.

7. **Firewall**:

   - Check **Allow HTTP traffic**. This automatically applies the `http-server` tag under the hood.

8. **Management → Metadata**:

   - Click the **Management** tab, then under **Metadata**, click **Add item**.

     - **Key**: `startup-script-url`
     - **Value**:

       ```
       gs://my-startup-scripts-<YOUR-UNIQUE-SUFFIX>/install-web.sh
       ```

   - Leave the inline “Startup script” field blank—only the URL is needed.

9. Click **Create**.

Once provisioning finishes, the VM will boot, fetch `install-web.sh` from your bucket, and run it. This should install Apache and drop a basic index page in `/var/www/html/index.html`.

---

#### C. Create the VM: gcloud CLI

Alternatively, from Cloud Shell or any authenticated terminal:

```bash
# 1. Define variables
PROJECT_ID=$(gcloud config get-value project)
ZONE=us-central1-c
INSTANCE_NAME=apache-vm-remote
BUCKET_NAME=my-startup-scripts-<YOUR-UNIQUE-SUFFIX>
SCRIPT_PATH=install-web.sh

# 2. (Re)Create firewall rule if needed
gcloud compute firewall-rules list \
  --filter="name~'allow-http' AND direction=INGRESS" \
  --format="value(name)" \
  | grep -q "allow-http" || \
  gcloud compute firewall-rules create allow-http \
    --project="$PROJECT_ID" \
    --description="Allow incoming HTTP (port 80)" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:80 \
    --target-tags=http-server

# 3. Launch the VM with metadata pointing to the script in Cloud Storage
gcloud compute instances create "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --tags=http-server \
  --metadata=startup-script-url="gs://$BUCKET_NAME/$SCRIPT_PATH"
```

- `--tags=http-server` ensures the VM inherits the firewall rule that allows inbound port 80.
- `--metadata=startup-script-url="gs://…/install-web.sh"` instructs Compute Engine to download and run that script on first boot.

After running this command, wait a minute or two while the instance boots and performs the installation.

---

## 4. Verify Apache Is Serving Over HTTP

### Concepts Covered

- **External IP Assignment**: When a new VM is created without specifying a static IP, GCE assigns an ephemeral external IP. You need that IP to test HTTP from your browser or with `curl`.
- **Startup Script Success Indicators**:

  - If Apache is installed and running, the default “Apache2 Debian Default Page” (or your custom content) should render.
  - A simple `curl` or `curl -I` to port 80 is often the quickest way to confirm from Cloud Shell.

### Steps

1. **Fetch the External IP**

   ```bash
   gcloud compute instances describe "$INSTANCE_NAME" \
     --zone="$ZONE" \
     --format="get(networkInterfaces[0].accessConfigs[0].natIP)"
   ```

   Let’s call the returned value `$EXTERNAL_IP`.

2. **Test via Browser**
   In your local machine’s browser, navigate to:

   ```
   http://$EXTERNAL_IP/
   ```

   You should see either:

   - The default Apache welcome page, or
   - A custom HTML snippet if `install-web.sh` overwrote `/var/www/html/index.html`.

3. **Test via `curl`** (from Cloud Shell or any terminal):

   ```bash
   curl -I http://$EXTERNAL_IP/
   ```

   A successful response looks like:

   ```
   HTTP/1.1 200 OK
   Date: Fri, 06 Jun 2025 15:00:00 GMT
   Server: Apache/2.4.52 (Debian)
   Last-Modified: ...
   Accept-Ranges: bytes
   Content-Length: ...
   Content-Type: text/html; charset=UTF-8
   ```

   - **`HTTP/1.1 200 OK`** means Apache responded successfully.
   - If you see a connection refused or timeout, double-check your firewall rule and tag.

---

## 5. Explanation of Core Concepts

1. **Why Store the Script in Cloud Storage?**

   - Centralized management: You can update or replace `install-web.sh` in one place rather than logging into each VM.
   - Version control: You can keep a local copy in a Git repo and push new versions to the bucket.
   - Security: You can use IAM to restrict who can read or modify the script.

2. **Metadata vs. Inline Startup Script**

   - **Inline Startup Script** (metadata key `startup-script`) embeds the entire shell script in VM metadata.
   - **Remote Startup Script** (metadata key `startup-script-url`) tells GCE to download a script from a Cloud Storage URL. This keeps metadata small and manageable.

3. **Network Tags & Firewall Rules**

   - A firewall rule in GCP often targets specific tags rather than individual IPs.
   - By tagging the VM with `http-server` and creating a rule that allows TCP:80 to `target-tags=http-server`, you keep your network rules organized and reusable.

4. **Region vs. Zone**

   - Buckets are regional. Storing `install-web.sh` in `us-central1` minimizes latency (and potential egress fees) for a VM in `us-central1-c`.
   - VMs run in a specific zone (`us-central1-c`). If you later create additional VMs in `us-central1-b` or `us-central1-a`, they can still fetch the script from the same bucket without any issues.

5. **`install-web.sh` Contents** (sample)

   ```bash
   #! /bin/bash
   apt-get update
   apt-get install -y apache2
   systemctl enable apache2
   systemctl start apache2

   # Optional: write a custom index page
   echo "<h1>Deployed via remote startup script</h1>" > /var/www/html/index.html
   ```

   - `apt-get update` ensures the local package index is fresh.
   - `apt-get install -y apache2` installs Apache without prompting.
   - `systemctl enable apache2` makes Apache start on every reboot.
   - `systemctl start apache2` starts Apache immediately on first boot.
   - The final `echo` replaces the default Apache index with a custom message, so you know you’re hitting _your_ script’s result, not a stale default.

---

## 6. Putting It All Together

Below is a consolidated shell snippet (for CLI users) that strings together Tasks 1–3. You can drop this into a local script, modify `<YOUR-UNIQUE-SUFFIX>`, and run step-by-step.

```bash
#!/bin/bash
# Replace <YOUR-UNIQUE-SUFFIX> with something globally unique.
SUFFIX="<YOUR-UNIQUE-SUFFIX>"
BUCKET_NAME="my-startup-scripts-$SUFFIX"
SCRIPT_PATH="install-web.sh"
ZONE="us-central1-c"
INSTANCE_NAME="apache-vm-remote"
PROJECT_ID=$(gcloud config get-value project)

# 1. Create the bucket
echo ">>> Creating bucket: gs://$BUCKET_NAME/"
gsutil mb -p "$PROJECT_ID" -l us-central1 -c standard "gs://$BUCKET_NAME/"

# 2. Copy the sample startup script into the bucket
echo ">>> Uploading install-web.sh into gs://$BUCKET_NAME/"
gsutil cp "gs://spls/gsp301/install-web.sh" "gs://$BUCKET_NAME/"

# 3. Ensure HTTP firewall rule exists (tag-based)
if ! gcloud compute firewall-rules list \
     --filter="name~'allow-http' AND direction=INGRESS" \
     --format="value(name)" | grep -q "allow-http"; then
  echo ">>> Creating firewall rule to allow HTTP (tcp:80)"
  gcloud compute firewall-rules create allow-http \
    --project="$PROJECT_ID" \
    --description="Allow incoming HTTP (port 80)" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:80 \
    --target-tags=http-server
else
  echo ">>> Firewall rule 'allow-http' already exists"
fi

# 4. Create the VM with remote startup script metadata
echo ">>> Creating VM: $INSTANCE_NAME in $ZONE"
gcloud compute instances create "$INSTANCE_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type=e2-micro \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --tags=http-server \
  --metadata=startup-script-url="gs://$BUCKET_NAME/$SCRIPT_PATH"

# 5. Wait briefly for the VM to boot and run the script
echo ">>> Waiting 60 seconds for VM to initialize..."
sleep 60

# 6. Retrieve the external IP
EXTERNAL_IP=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --zone="$ZONE" \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)")

echo ">>> Apache VM is ready at: http://$EXTERNAL_IP/"
echo ">>> You can run: curl -I http://$EXTERNAL_IP/ to verify Apache"
```

> **Note**: The script above sleeps for 60 seconds to give the VM time to finish the startup script. Depending on your network speed, you may need more or less time. Adjust as necessary.

---

## 7. Post-Deployment Considerations

1. **Updating or Versioning the Script**

   - If you modify `install-web.sh` to add new packages or configurations, re-save it in the same bucket path. Only _new_ VMs (or VMs that reboot with metadata re-execution enabled) will pick up the changes. Existing VMs do **not** automatically re-run the startup script on every reboot by default; they execute it only once at first boot. If you need re-runs, you can add a small wrapper in `install-web.sh` that checks a flag or uses `gsutil cp` to fetch a “marker file” that indicates whether to proceed.

2. **IAM Permissions on the Bucket**

   - By default, the Compute Engine **default service account** (e.g., `PROJECT_NUMBER-compute@developer.gserviceaccount.com`) has read access to Cloud Storage objects in the same project. If you use a **custom service account**, ensure it has at least `roles/storage.objectViewer` on your bucket so it can fetch `install-web.sh`.

3. **Logging & Troubleshooting**

   - If Apache doesn’t appear, SSH into the VM and inspect `/var/log/syslog` (Debian/Ubuntu) or `/var/log/messages` (CentOS/RHEL) to see startup-script execution errors. You can also check `/var/log/startupscript.log` for any stdout/stderr from your script.
   - Verify the VM actually downloaded the script:

     ```bash
     sudo ls /home
     # or wherever your script may have temporarily landed
     ```

   - Confirm the firewall rule and network tag if port 80 is blocked.

4. **Scaling & Automation**

   - Once you have a solid `install-web.sh`, you can use the same bucket path for a **managed instance group** template, allowing autoscaling of identical VMs. All group members will run the same startup logic.
   - For more complex initialization (installing application code, SSL certs, secrets), you might pivot to using [Cloud Init](https://cloud.google.com/compute/docs/import/import-existing-image#windows) patterns or configuration management tools (Ansible, Puppet, etc.). But for simple “install Apache and serve,” a remote startup script is lightweight and effective.

---

## 8. Conclusion

By following this playbook, you’ve:

- **Centralized** your startup logic into a Cloud Storage bucket.
- **Versioned** and **updated** your initialization script without touching VM metadata directly.
- **Automated** the provisioning of a Linux VM in `us-central1-c` that installs and starts Apache on first boot.
- Verified public HTTP access to the VM through a tag-based firewall rule.

This approach is ideal for small fleets of VMs or managed instance groups where you want a single source of truth for all startup logic. You can include this entire playbook in your repo’s README so that any team member—or automated CI/CD pipeline—can follow the same steps to spin up an identical environment.

---

### Example Repo README Snippet

````markdown
## Deploy Apache VM with Remote Startup Script

This repository contains instructions for deploying a Compute Engine VM that installs Apache on boot using a startup script stored in Cloud Storage.

### 1. Create a Storage Bucket

```bash
gsutil mb -p $(gcloud config get-value project) -l us-central1 -c standard gs://my-startup-scripts-<SUFFIX>/
```
````

### 2. Upload `install-web.sh`

```bash
gsutil cp gs://spls/gsp301/install-web.sh gs://my-startup-scripts-<SUFFIX>/
```

### 3. Create Firewall Rule (if needed)

```bash
gcloud compute firewall-rules create allow-http \
  --description="Allow incoming HTTP (port 80)" \
  --direction=INGRESS --action=ALLOW \
  --rules=tcp:80 --target-tags=http-server
```

### 4. Launch the VM

```bash
gcloud compute instances create apache-vm-remote \
  --zone=us-central1-c \
  --machine-type=e2-micro \
  --image-family=debian-11 --image-project=debian-cloud \
  --tags=http-server \
  --metadata=startup-script-url=gs://my-startup-scripts-<SUFFIX>/install-web.sh
```

### 5. Verify HTTP Access

```bash
EXTERNAL_IP=$(gcloud compute instances describe apache-vm-remote \
  --zone=us-central1-c \
  --format="get(networkInterfaces[0].accessConfigs[0].natIP)")
curl -I http://$EXTERNAL_IP/
```

If you see `HTTP/1.1 200 OK`, Apache is serving correctly.

---

### More Information

- The bucket holds `install-web.sh`. Edit it in your bucket to adjust Apache or add application code.
- Ensure the VM’s service account has `storage.objectViewer` on the bucket.
- For multi-VM or managed instance groups, reuse the same `startup-script-url` metadata in your instance template.

```

Feel free to copy, tweak, or extend this playbook in your own repository so that anyone on your team can replicate the environment quickly and consistently.
```
