## Migrating a **WordPress MySQL** database to **Google Cloud SQL for MySQL**

This playbook walks you through the full cut-over—from a “pet” VM running LAMP to a managed Cloud SQL backend—so you can drop it straight into your repository’s README.

---

### Architecture at the end of the play

```
┌────────────┐     3306/TCP     ┌──────────────────────────┐
│ blog  VM   │ ───────────────▶ │  Cloud SQL instance      │
│  Apache +  │                  │  • MySQL 8.0 (regional)  │
│  WordPress │                  │  • Backups / IAM / HA    │
└────────────┘                  └──────────────────────────┘
```

_The WordPress code stays on the VM; only the data tier moves._

---

## 0. Prerequisites

1. **Cloud SQL Admin API** – must be enabled on the project.
2. **IAM** – your user (or automation SA) needs the role `roles/cloudsql.admin`.
3. **Billing** – Cloud SQL is billable; every Qwiklabs/GSP lab has this covered.
4. **mysqldump** & **mysql-client** installed on the VM (they ship with most LAMP images).

---

## 1. Create a Cloud SQL (MySQL) instance in **us-east1**

> Use either Console **or** CLI—the parameters are identical.

| Setting      | Recommended value                                                                      | Why                                          |
| ------------ | -------------------------------------------------------------------------------------- | -------------------------------------------- |
| Engine       | MySQL 8.0 (2ⁿᵈ-gen)                                                                    | WordPress supports 5.7+, use latest.         |
| Tier         | `db-n1-standard-2`                                                                     | 2 vCPU / 7.5 GB is roomy for modest traffic. |
| Storage      | 10 GB SSD, auto-resize                                                                 | Fast + won’t run out mid-import.             |
| Region       | `us-east1`, zone-pref `us-east1-d`                                                     | Same zone as the blog VM reduces latency.    |
| Backups      | ON + binary logging                                                                    | Enables PITR.                                |
| Connectivity | Private IP if VPC-peered, else Public IP + VM’s external IP in **Authorized networks** | Locks access down to the VM.                 |

<details><summary>CLI snippet</summary>

```bash
gcloud sql instances create wordpress-sql \
  --database-version=MYSQL_8_0 \
  --tier=db-n1-standard-2 \
  --storage-type=SSD \
  --storage-size=10GB \
  --storage-auto-increase \
  --region=us-east1 \
  --root-password="StrongRootPW_ChangeMe" \
  --zone=us-east1-d
```

</details>

---

## 2. Prepare the **wordpress** schema & credentials

```bash
# Create DB
gcloud sql databases create wordpress --instance=wordpress-sql

# Create user identical to on-prem
gcloud sql users create blogadmin --instance=wordpress-sql \
     --password="Password1*" --host="%"

# Grant privileges
gcloud sql connect wordpress-sql --user=root --quiet <<'SQL'
GRANT ALL PRIVILEGES ON wordpress.* TO 'blogadmin'@'%';
FLUSH PRIVILEGES;
SQL
```

> _Why ALL privileges?_ WordPress core and plug-ins need DDL rights for upgrades.

---

## 3. Dump from the VM and import into Cloud SQL

### 3-A Create a consistent SQL dump on the **blog** VM

```bash
sudo mysqldump \
  --user=blogadmin --password='Password1*' \
  --databases wordpress \
  --single-transaction --set-gtid-purged=OFF \
  | gzip > /tmp/wordpress-$(date +%Y%m%d%H%M).sql.gz
```

_`--single-transaction` gives a snapshot without table locks._

### 3-B Copy the file to Cloud Shell (one-liner)

```bash
gcloud compute scp blog:/tmp/wordpress-*.sql.gz .
```

### 3-C Stream the dump directly into Cloud SQL (no Cloud Storage required)

```bash
gunzip -c wordpress-*.sql.gz | \
  gcloud sql connect wordpress-sql \
        --user=blogadmin --quiet -- \
        -D wordpress          # forwarded to mysql client
```

> Anything after `--` is passed to `mysql`; `-D wordpress` selects the schema.
> Cloud SQL Auth Proxy spins up automatically during `gcloud sql connect`. ([cloud.google.com][1])

Validate:

```bash
gcloud sql connect wordpress-sql --user=blogadmin --quiet -- -e \
  "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='wordpress' LIMIT 5;"
```

---

## 4. Re-point WordPress (`wp-config.php`) to Cloud SQL

1. **Get the Cloud SQL IP**

   ```bash
   SQL_IP=$(gcloud sql instances describe wordpress-sql \
            --format='value(ipAddresses[0].ipAddress)')
   echo $SQL_IP
   ```

2. **Back up & edit the config on the VM**

   ```bash
   gcloud compute ssh blog --zone=us-east1-d
   sudo cp /var/www/html/wordpress/wp-config.php \
           /var/www/html/wordpress/wp-config.php.backup
   sudo nano /var/www/html/wordpress/wp-config.php
   ```

   Update the four lines:

   ```php
   define( 'DB_NAME',     'wordpress' );
   define( 'DB_USER',     'blogadmin' );
   define( 'DB_PASSWORD', 'Password1*' );
   define( 'DB_HOST',     'XX.XX.XX.XX' );   // <- replace with $SQL_IP
   ```

   _If you installed the Cloud SQL Proxy as a service on the VM, use `127.0.0.1` instead._ ([wpbeginner.com][2])

3. **Restart Apache/PHP-FPM**

   ```bash
   sudo systemctl restart apache2   # Debian/Ubuntu
   ```

4. **Decommission local MySQL (optional)**

   ```bash
   sudo systemctl stop mysql
   sudo systemctl disable mysql
   ```

Open the blog’s URL—if pages load, the migration is live. A “database connection error” means DB_HOST, user, password or firewall is wrong.

---

## 5. Post-migration checklist

| Item                                                                                            | Command / Location                                                                                                                                  |
| ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Confirm automated backups                                                                       | `gcloud sql backups list --instance=wordpress-sql`                                                                                                  |
| Grant Cloud SQL service-agent least-priv GCS access **if you later use bucket imports/exports** | `gsutil iam ch serviceAccount:service-<PROJECT_NUM>@gcp-sa-cloud-sql.iam.gserviceaccount.com:objectViewer gs://YOUR_BUCKET` ([cloud.google.com][3]) |
| Enable slow-query log for tuning                                                                | Instance → **Edit → Flags → slow_query_log=on**                                                                                                     |
| Enforce SSL from WordPress (optional)                                                           | `define( 'MYSQL_CLIENT_FLAGS', MYSQLI_CLIENT_SSL );`                                                                                                |

---

### 🎉 Results

- WordPress now uses a fully-managed Cloud SQL backend with automated backups and IAM-based access control.
- The VM is lighter (no MySQL), patching surface is smaller, and you can scale reads in future by adding read replicas.

---

#### References

- Cloud SQL roles & required IAM for GCS import/export ([cloud.google.com][3])
- `gcloud sql import sql` syntax & proxy behaviour ([cloud.google.com][1])
- Safe editing of `wp-config.php` / DB_HOST guidance ([wpbeginner.com][2])

[1]: https://cloud.google.com/sdk/gcloud/reference/sql/import/sql?utm_source=chatgpt.com "gcloud sql import sql | Google Cloud CLI Documentation"
[2]: https://www.wpbeginner.com/beginners-guide/how-to-edit-wp-config-php-file-in-wordpress/?utm_source=chatgpt.com "How to Edit wp-config.php File in WordPress (Step by Step)"
[3]: https://cloud.google.com/sql/docs/mysql/roles-and-permissions?utm_source=chatgpt.com "Roles and permissions | Cloud SQL for MySQL"
