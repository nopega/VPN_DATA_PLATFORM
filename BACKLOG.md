# Backlog

Known gaps in what is built so far, with the reason each matters and when it
stops being optional. Written 12 October 2026, after stages 01–05.

## Before something specific happens

| When | Item | Why |
|---|---|---|
| **Before the next component** | **Pod limit on the single t3.medium (17 pods)** | Set by how many network addresses the instance type can hold, not by CPU or memory. System pods, the load balancer controller, external-dns and Argo CD already use ~16. Options: a second node (`ondemand_desired = 2`, ~$42/mo), a larger type, or VPC CNI prefix delegation (lifts the limit to 110 on the same node; needs the node replaced). |
| **Before the Tailscale auth key expires** (≤90 days from creation) | Rotate the key in Secrets Manager | The running router is unaffected — it already joined. But any rebuild of the router (a changed boot script, a destroy/apply) needs a valid key to join again. Generate a new reusable key and `aws secretsmanager put-secret-value --secret-id vpn-data-platform/tailscale-auth-key --secret-string ...`. |
| **Before inviting anyone else to the tailnet** | Tailscale ACLs | The default policy lets every tailnet member reach everything, including the whole VPC through the subnet route. Restrict it (for example: members reach only the ALB's port 443; admins reach the Kubernetes API). |
| **Before installing anything important** | A second EKS admin | Only the IAM identity that ran `terraform apply` in stage 03 is cluster admin. If that identity changes or is lost, nobody can use kubectl. Add an access entry for a second principal. |
| **Before a second person runs Terraform** | Move state to S3 with `use_lockfile = true` | State is on one laptop. Lose it and Terraform forgets what it built; two people with two copies will fight. Stages 02–05 read stage 01's state from `../01_vpc/terraform.tfstate`, so they move together. |
| **Before moving each old service** | Delete its old Cloudflare record | `trino`, `airflow`, `harbor`, `grafana`, `prometheus` still point at the old platform's deleted ALB. external-dns will not overwrite a record it does not own. Keep `ssh.nopega.net`. |

## Whenever there is time

| Item | Why |
|---|---|
| Router recovers itself | If the instance fails, nothing replaces it: users lose the way in, nodes lose the way out. An Auto Scaling group of one, or an EC2 recover alarm, would bring it back without a human. |
| Router OS updates | It accepts UDP from the internet (Tailscale's port) and nothing patches it. `dnf upgrade` on a schedule, or rebuild it from the latest AMI periodically. |
| Old ACM validation records in Cloudflare | Seven `_….nopega.net` CNAMEs for the old per-name certificates. Harmless, just clutter. **Do not delete `_d23aca41….nopega.net`** — it belongs to the current wildcard certificate and ACM re-reads it to renew. |
| `problem2_answer/docs/COST.md` | Quotes the NAT gateway at $32/mo — the us-east-1 rate. Singapore is $0.059/hr, about $43/mo. |
| `problem2_answer` Kubernetes version | The original runs 1.34, whose standard support ends **2 December 2026**. Rebuilding it unchanged after that date bills the control plane at the extended rate, six times higher. |
| Split DNS for the EKS endpoint | The Tailscale split-DNS rule for `ap-southeast-1.eks.amazonaws.com` may not be needed if the private endpoint name resolves publicly. Confirm with `dig @1.1.1.1 <endpoint host>`; if it returns 10.42.x.x, remove the rule and the README section in stage 03. |
