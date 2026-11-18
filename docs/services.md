# Service documentation

Every service in [infra/cloudformation/exam-platform.yaml](../infra/cloudformation/exam-platform.yaml), with the alternative it was chosen over and how it is configured. Stack name `exams-prod`, region `us-east-1`, two AZs (`us-east-1a`, `us-east-1b`).

## Edge and frontend

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Amazon Route 53** | DNS for `exams.example.edu` | Alias records to CloudFront are free and resolve at the apex, which the university's external DNS cannot do. 100% SLA on the DNS data plane. | Public hosted zone; `A` alias → CloudFront (zone `Z2FDTNDATAQYW2`); also holds the ACM validation record | CloudFront, ACM |
| **Amazon CloudFront** | One HTTPS entry point: SPA (`/*`) and API (`/api/*`) | Absorbs the 3,000-student page-load spike at 600+ edge locations, unlike serving the SPA from EC2/ALB. One domain means no CORS for the API. Carries WAF and TLS. | HTTP/2+3; `redirect-to-https`; default behaviour → S3 with *CachingOptimized*; `/api/*` → API Gateway with *CachingDisabled* + *AllViewerExceptHostHeader*; TLS 1.2_2021; access logs to the logs bucket | Route 53, WAF, ACM, S3 frontend, API Gateway |
| **AWS Certificate Manager** | TLS certificate | Free, auto-renewing public certificate, compared with buying and rotating one by hand | DNS validation through the Route 53 zone; attached to CloudFront (SNI) | CloudFront, Route 53 |
| **AWS WAF** | Layer-7 filtering in front of everything | Managed rule groups block OWASP-style attacks with no rule-writing. Shield/NACLs alone cannot inspect HTTP. | Web ACL, scope `CLOUDFRONT`: `AWSManagedRulesCommonRuleSet`, `KnownBadInputs`, `SQLiRuleSet`; rate-based rule of 20,000 req / 5 min per IP (kept high because a whole campus shares one NAT IP); metrics to CloudWatch | CloudFront |
| **Amazon S3 – frontend bucket** | Hosts the HTML/JS/CSS single-page app | Static hosting costs cents and needs no servers to patch or scale, compared with Nginx on EC2 | Block Public Access on; readable only by this distribution via Origin Access Control (bucket policy on `AWS:SourceArn`); SSE-S3; deploy pipeline syncs with `--delete` | CloudFront |

## Identity, API and compute

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Amazon Cognito** | Role-based sign-in for students, tutors and admins | Managed user directory with JWTs, MFA and SAML federation to the university IdP. Saves writing and securing a custom auth service. Free for 50,000 MAU, and we have 8,400 users. | User pool, admin-created users only, password ≥ 12 chars, optional TOTP MFA; groups `Students`, `Tutors`, `Admins` (role read from `cognito:groups`); app client `web`, no secret, SRP/password flows, 4 h tokens | Browser, API Gateway authorizer |
| **Amazon API Gateway (HTTP API)** | Public API for the SPA | HTTP API is ~70% cheaper and faster than a REST API and has a built-in Cognito JWT authorizer. An ALB would need the app to validate tokens and would not throttle per route. | Routes `GET /api/health` (open) and `ANY /api/{proxy+}` (JWT authorizer: issuer = user pool, audience = app client); stage `$default`, throttle 2,000 rps / burst 5,000; JSON access logs to CloudWatch; CORS restricted to the site origin | CloudFront, Cognito, Lambda |
| **AWS Lambda** | `exam-api` (router), `marker`, `upload-processor`, `notifier`, `db-migrate` | Scales from 0 to thousands of instances in seconds for the 5-minute exam burst. ECS/EC2 auto scaling takes minutes and we would pay for idle capacity between exam weeks. | Node.js 22, arm64 (Graviton, ~20% cheaper); in both private app subnets with `sg-lambda`; X-Ray active; `exam-api` 512 MB/15 s with alias `live`; `marker` reserved concurrency 20 to protect Aurora; SQS triggers use `ReportBatchItemFailures`; code from a content-hashed S3 bundle | API Gateway, DynamoDB, Aurora, S3, SQS, SES, Secrets Manager |
| **Application Auto Scaling** | Scheduled provisioned concurrency for `exam-api:live` | Pre-warms 300 instances 15 minutes before each exam window, so there are no cold starts at the peak. Keeping them warm all day would cost far more. | Scheduled actions `exam-window-warm` (Mon–Fri 08:45 BTT → min 300) and `exam-window-cool` (12:00 → 0) | Lambda |

## Network

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Amazon VPC + subnets** | Private network isolating compute and data | Three tiers in two AZs give AZ-level fault isolation, which a single subnet or a default VPC does not | `10.20.0.0/16`; public `10.20.0.0/24` / `.1.0/24`; private app `10.20.10.0/24` / `.11.0/24`; private data `10.20.20.0/24` / `.21.0/24` (route table has **no** internet route) | All VPC resources |
| **Internet gateway** | Internet access for the public subnets | Required for NAT. Nothing else is publicly addressable. | Attached to the VPC; default route only in the public route table | NAT gateways |
| **NAT gateway (×2)** | Outbound internet for Lambda (e.g. SES, Cognito JWKS) | Managed and highly available within its AZ, unlike a NAT instance we would have to patch. **One per AZ**, so losing AZ-a does not cut AZ-b's egress. | NAT-A in public-a, NAT-B in public-b; app route table A → NAT-A, app route table B → NAT-B | Lambda, internet gateway |
| **VPC gateway endpoints** | Private path to S3 and DynamoDB | Free, compared with paying NAT data charges for every autosave and file read; traffic never leaves AWS | Gateway endpoints for `s3` and `dynamodb` on both app route tables | Lambda, S3, DynamoDB |
| **Security groups** | Instance-level firewall | Stateful, reference-based rules ("only Lambda may reach Aurora") instead of CIDR-based NACLs | `sg-lambda`: egress only; `sg-aurora`: TCP 5432 **only from `sg-lambda`** | Lambda, Aurora |

## Data and storage

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Amazon Aurora PostgreSQL** | System of record: exams, results, submissions, tutors (relational, 5 years) | Storage keeps 6 copies across 3 AZs, failover takes under 60 s, and point-in-time restore goes to any second, all stronger than RDS PostgreSQL Multi-AZ or self-managed Postgres on EC2. PostgreSQL suits relational reporting on marks. | Engine 16.8; **writer in AZ-a, reader in AZ-b** (promotion tier 1 = failover target); isolated data subnets; encrypted with the platform KMS key; 35-day backup retention; deletion protection + snapshot on delete; credentials from Secrets Manager; Postgres logs to CloudWatch | Lambda, Secrets Manager, KMS, AWS Backup |
| **Amazon DynamoDB** | Hot path: published exam papers (`exams`) and autosaved answers (`attempts`) | Single-digit-ms writes that scale with no connection limit, so 100 autosaves/s at peak never touch Aurora. On-demand costs nothing between exams; Aurora would need oversized instances for the burst. | Two tables, `PAY_PER_REQUEST`; `attempts` key `studentId` + `examId`, GSI `byExam`; conditional writes enforce the deadline; **PITR on** (35 days, RPO seconds); SSE-KMS | Lambda, AWS Backup, KMS |
| **Amazon S3 – submissions bucket** | Stores assignment files (PDF/ZIP ≤ 50 MB) for 5 years | Cheaper and more durable (11 nines) than EBS/EFS. Presigned POSTs keep 50 MB uploads off the API (API Gateway caps payloads at 10 MB). Lifecycle tiers cut 5-year storage cost by ~90%. | Versioning; Block Public Access; SSE-KMS + bucket key; TLS-only policy; CORS for the site origin; lifecycle Standard → IA 30 d → Glacier IR 180 d → Deep Archive 365 d → **delete after 1,830 d**, abort multipart after 7 d; `ObjectCreated` events → SQS | Browser (presigned POST), Lambda, SQS, KMS |
| **Amazon S3 – logs bucket** | CloudFront and CloudTrail logs | Durable and cheap, with a lifecycle rule to Glacier, compared with keeping audit logs in CloudWatch for 5 years | Block Public Access; SSE-S3; Glacier after 90 d, expire after 1,830 d; bucket policy for CloudTrail | CloudFront, CloudTrail |

## Asynchronous processing and messaging

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Amazon SQS** | Buffers marking jobs, upload events and notifications | A queue absorbs the 3,000-submission burst and retries failures; synchronous marking would block students and overload Aurora. Simpler and cheaper than Kinesis for independent jobs. | Queues `marking` (180 s visibility), `upload-events`, `notify`; each has a **DLQ** (`maxReceiveCount` 5, 14-day retention) and KMS/SSE; queue policy lets only the submissions bucket send to `upload-events` | API Lambda, S3, worker Lambdas |
| **Amazon SES** | Tutor "new submission" and "results released" emails | Pay-per-email transactional delivery with DKIM/SPF, compared with running an SMTP server | Verified sender identity `no-reply@exams.example.edu`; IAM allows `ses:SendEmail` only from that address; only the `notifier` Lambda sends | Notifier Lambda |
| **Amazon SNS** | Operations alert fan-out | One alarm notifies email (and later SMS/chat) subscribers, without wiring each alarm separately | Topic `ops-alerts`, email subscription to the cloud-ops list | CloudWatch alarms |

## Security, operations and delivery

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **AWS KMS** | Encryption at rest for every data store | A customer-managed key gives one auditable key policy and lets us revoke access, unlike per-service default keys | One symmetric CMK `alias/exams-prod-data`, **annual rotation on**; used by Aurora, DynamoDB, S3, SQS, Secrets Manager, AWS Backup | All data services |
| **AWS Secrets Manager** | Aurora master credentials | Generated, encrypted and rotatable, compared with putting passwords in environment variables or code | Secret `exams-prod/aurora/master` (32-char generated password, KMS); read at Lambda cold start; rotation every 30 days on AWS | Aurora, Lambda |
| **AWS IAM** | Least-privilege roles | Per-function permissions instead of shared access keys | Lambda role limited to the two tables, `submissions/*` objects, the three queues, one secret, the KMS key and SES from one sender; backup role uses the AWS managed backup policy; CI uses GitHub **OIDC** (no stored keys) | All services |
| **Amazon CloudWatch** | Logs, metrics, alarms, exam-day dashboard | Native to every service used, so no agents or a separate monitoring stack are needed | Alarms: API 5xx > 10/min for 3 min, `exam-api` throttles > 0, marking/notify DLQ not empty, Aurora CPU > 80%; all → SNS; dashboard `exams-prod-exam-day`; 90-day log retention | All services, SNS |
| **AWS X-Ray** | Distributed tracing | Shows where latency sits (API Gateway → Lambda → DynamoDB/Aurora) during the peak, which logs alone do not | Active tracing on every Lambda | Lambda |
| **AWS CloudTrail** | Audit trail of every API call | Required for exam-integrity investigations; immutable, validated logs | Multi-region trail, log-file validation on, delivered to the logs bucket (kept 5 years) | Logs bucket |
| **AWS Backup** | Long-term retention of exam records | Central policy across Aurora and DynamoDB, beyond Aurora's 35-day limit, to meet the 5-year rule | Vault encrypted with the KMS key; plan `daily-35d` and `monthly-5y` (cold storage after 90 d, delete after 1,830 d); selection: Aurora cluster + both tables | Aurora, DynamoDB, KMS |
| **AWS CloudFormation** | Infrastructure as code for the entire stack | Native and free, with change sets and rollback; supported by the emulator used for testing (Terraform would need a separate state backend) | One template, ~100 resources, parameter `Platform` = `aws` / `emulator`; `cfn-lint` clean | Every resource |
| **GitHub Actions** | CI/CD: push to `main` → validate → deploy → smoke test | Free for the repository and lives next to the code. CodePipeline would add a CodeCommit/CodeStar connection and per-pipeline cost. | `.github/workflows/deploy.yml`: job `validate` (cfn-lint, `node --check`, shellcheck), then `deploy-emulator` (self-hosted runner) or `deploy-aws` (OIDC role); concurrency guard, so no overlapping stack updates | GitHub, CloudFormation |
| **AWS Fault Injection Service** | Rehearses the loss of an AZ on real AWS | Controlled, repeatable experiments with a CloudWatch stop condition, safer than manually breaking production | [infra/fis/az-a-outage.json](../infra/fis/az-a-outage.json): Aurora failover + `network:disrupt-connectivity` on AZ-a subnets for 10 min; stops if the 5xx alarm fires | Aurora, VPC subnets, CloudWatch |
