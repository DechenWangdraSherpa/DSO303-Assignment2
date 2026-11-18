# evidence/: Cloud Architecture Lab build (Task 3)

Everything for the Cloud Architecture Lab part of Task 3. Five ready-made lab files in [lab-json/](lab-json/) load the complete design into the lab. You then run each simulation there and save one screenshot per file into this folder.

| Import this file | Mode | Save the screenshot as | Proves |
|---|---|---|---|
| `lab-json/lab-01-full-architecture.json` | Design | `lab-01-full-architecture.png` | Full build: edge, VPC, 2 AZs × 3 subnet tiers, regional services, CI/CD |
| `lab-json/lab-02-walkthrough1.json` | Simulate | `lab-02-walkthrough1-exam-autosave.png` | Walkthrough 1: student opens the exam and autosaves (HTTP 200) |
| `lab-json/lab-03a-walkthrough2-upload.json` | Simulate | `lab-03a-walkthrough2-upload.png` | Walkthrough 2, part 1: 40 MB upload → S3 → SQS → upload-processor (HTTP 202) |
| `lab-json/lab-03b-walkthrough2-notify.json` | Simulate | `lab-03b-walkthrough2-tutor-notified.png` | Walkthrough 2, part 2: upload-processor → SQS notify → notifier → SES email to the tutor |
| `lab-json/lab-04-az-failure.json` | Failure Lab | `lab-04-az-failure.png` | AZ-A outage: no cascades, everything fails over to AZ-B, and the request still succeeds (HTTP 200) |

**Why walkthrough 2 has two files.** The lab follows AWS's asynchronous behaviour: when an SQS consumer Lambda has processed and deleted a message, the original request is complete (HTTP 202). The notification therefore runs as its own execution, starting from the upload-processor Lambda, which is what file 03b loads. The lab does not model Amazon SES as an executable hop yet, so the SES → tutor email is drawn as a documented link. The real SES email is shown in `screenshots/06-wt2-upload-to-tutor-email-backend.png`.

All five files were checked before you import them. I ran each one through the lab's own simulation engine (source: github.com/norbutlepcha25/cloud-architecture-lab) in an isolated container. The results you should see are listed under each step below.

---

## Before you start (once)

1. Open the lab: `https://main.d35uam9e2t7065.amplifyapp.com/#lab`.
2. Make the browser full screen (**F11**). Screenshots then show only the lab.
3. Use the light or dark theme (the ☀ icon in the top bar); either is fine, but use the same one for all five shots.
4. Take screenshots with **Firefox: Ctrl + Shift + S → "Save visible"**. Alternatively, on Kali press **Print Screen** (Xfce Screenshooter), choose *Entire screen*, and save as PNG.
5. Save every image into this `evidence/` folder with the exact file name from the table above.

**How to import a file (used in every step):**
1. Click **Export** (top-right).
2. Click **Upload JSON**.
3. Pick the file from `Assignment2/evidence/lab-json/` and close the dialog.

The canvas is replaced with that file's design, scenario and failures. If you're asked about unsaved work, it's fine to discard it.

**How to fit the whole design on screen (used in every step):**
1. Click the **⛶ (fit view)** button at the bottom-left of the canvas, under the + and − buttons.
2. To get more space, collapse the **Service library** panel (the ⊟ icon to the right of "Service library") and the right inspector panel (the ⊟ icon at the top-right edge).

---

## 1. `lab-01-full-architecture.png`: the full build

1. Import `lab-01-full-architecture.json`.
2. Click **Design** in the top bar.
3. Collapse the side panels and click **⛶ fit view**, so the whole design fits: the Student and Tutor on the left, the region box, and the CI/CD row at the bottom.
4. Click on an empty part of the canvas, so nothing is selected.
5. Check that you can see all of these:
   - the **Route 53 → CloudFront + ACM → WAF** edge column;
   - **S3 frontend, API Gateway, Cognito and SES** along the top of the region;
   - the **VPC 10.20.0.0/16** with **Availability Zone A** and **Availability Zone B**, each holding a **Public subnet** (NAT gateway), a **Private app subnet** (Lambda) and a **Private data subnet** (Aurora writer in A, Aurora reader in B);
   - the **Internet Gateway** at the top of the VPC and the **Gateway endpoints** at the bottom;
   - on the right: **AWS Backup** (top, linked to DynamoDB), **DynamoDB, S3 submissions, three SQS queues, Dead-letter queues, KMS, Secrets Manager, CloudWatch → X-Ray, SNS, IAM, and CloudTrail → S3 audit logs**;
   - **no "stray components" warning** at the top of the canvas;
   - along the bottom: **GitHub → GitHub Actions → CloudFormation**.
6. Take the screenshot and save it as `lab-01-full-architecture.png`.

*Optional extra:* the image icon next to **Export** (**Download PNG**) saves a clean image of just the canvas. You can keep it as `lab-01-full-architecture-canvas.png`.

## 2. `lab-02-walkthrough1-exam-autosave.png`: Walkthrough 1

1. Import `lab-02-walkthrough1.json`. It opens in **Simulate** mode.
2. Click **⛶ fit view**.
3. Check the bottom bar. It should show method **PUT**, path **/api/exams/DSO303-MIDTERM/autosave**, and **Assume route tables** ticked. Leave **Task flow** switched on.
4. Click **Send Request**. The request animates. Click **▶** if playback is paused, and let it finish.
5. **Expected result: HTTP 200, "Request successfully processed across all architectural tiers".** The event timeline above the bottom bar lists the hops:
   - Student → Route 53 (DNS);
   - Route 53 → CloudFront;
   - CloudFront → API Gateway (edge cache MISS, forwarded to origin);
   - API Gateway → **Lambda (AZ-A)**;
   - **IAM authorization** of the Lambda role;
   - Lambda → NAT gateway A (route table);
   - Lambda → **DynamoDB** (Query completed);
   - **HTTP 200 response delivered** to the Student.
6. Make sure the screenshot shows the highlighted path on the canvas **and** the step list with **HTTP 200**. If the step list is collapsed, click **Trace** to open the decision-by-decision trace and include it.
7. Save it as `lab-02-walkthrough1-exam-autosave.png`.

The autosave repeats every 30 seconds, and each repeat is this same request. If you want, run **Send Request** a second time and capture it as `lab-02b-...png`, but one shot is enough.

## 3a. `lab-03a-walkthrough2-upload.png`: Walkthrough 2, part 1 (upload)

1. Import `lab-03a-walkthrough2-upload.json`.
2. Click **⛶ fit view**.
3. Check the bottom bar: method **POST**, path **/submissions/DSO303/A2/student1/assignment2.pdf**.
4. Click **Send Request** and let the animation finish.
5. **Expected result: HTTP 202, "SQS upload-events: operation accepted. Consumers: Lambda (AZ-B): processed; Lambda (AZ-A): processed".** The steps are:
   - Student → **S3 submissions** (Object access: the presigned POST, which never goes through the API);
   - S3 → **SQS upload-events** (`sqs: send`, the `s3:ObjectCreated` event);
   - **Lambda event source mapping** → Lambda (AZ-B) *process and delete*, and the same for Lambda (AZ-A);
   - **HTTP 202 delivered**.
6. Take the screenshot (highlighted path plus step list) and save it as `lab-03a-walkthrough2-upload.png`.

## 3b. `lab-03b-walkthrough2-tutor-notified.png`: Walkthrough 2, part 2 (tutor notified)

1. Import `lab-03b-walkthrough2-notify.json`. This run starts at the upload-processor, **Lambda (AZ-B)**.
2. Click **⛶ fit view**.
3. Click **Send Request** and let it finish.
4. **Expected result: HTTP 202, "SQS notify: operation accepted. Consumers: Lambda (AZ-A): processed; Lambda (AZ-B): processed".** The steps are:
   - Lambda (AZ-B) → **SQS notify**: endpoint reached via the NAT, **IAM authorization**, `sqs: send`;
   - **Lambda event source mapping** → the notifier Lambda *process and delete*;
   - **HTTP 202**.
5. Before you capture, make sure the dashed **Lambda → Amazon SES → Tutor (email inbox)** links ("SendEmail" and "[DSO303] New submission for A2") are visible on the canvas. They show where the notifier sends the email.
6. Save it as `lab-03b-walkthrough2-tutor-notified.png`.

## 4. `lab-04-az-failure.png`: loss of one Availability Zone

1. Import `lab-04-az-failure.json`. It opens in **Failure Lab** with the **AZ-A outage already injected**.
   - If the red strip under the top bar shows no "Impact" message, click **Restore all** and then **AZ-A outage**.
2. Click **⛶ fit view**. **NAT gateway A, Lambda (AZ-A) and the Aurora writer** should be shown as failed.
3. Read the **Impact** message in the strip. Expected: **"az_failure on AZ-A: 3 resource(s) directly failed. 5 dependent(s) fully survived via redundancy (API Gateway HTTP API, SQS notify, SQS upload-events, SQS marking, Lambda (AZ-B))."** Hover over it to read the full text. There should be **no** "cascaded" resources.
4. Without restoring, click **Send Request** in the bottom bar (still the walkthrough 1 autosave).
5. **Expected result: HTTP 200.** API Gateway now routes to **Lambda (AZ-B)**, which uses **NAT gateway B** and DynamoDB. The exam keeps working while AZ-A is down.
6. **Important:** Send Request switches the lab to the **Simulate** tab, which hides the failure strip. Click **Failure Lab** in the top bar again. The run's timeline and HTTP 200 stay on screen, and the Impact strip and failed AZ-A nodes come back.
7. Take the screenshot so it shows **the Impact strip, the failed AZ-A resources and the timeline ending in HTTP 200 via Lambda (AZ-B)**. Save it as `lab-04-az-failure.png`.
7. *Optional:* click a failed node, such as **Aurora PostgreSQL writer**, to see in the right panel why it fails over ("Multi-AZ / inherently resilient and automatically fails over"). You can capture this as `lab-04b-az-failure-details.png`.

---

## If something looks different

- **"Invalid draft data" or "Unsupported draft format" when importing.** The lab has been updated. Send me the message and the version shown at the bottom-left (yours was `stable · v1.0.0 · e0a42ea0`).
- **A node sits on the edge of a box.** Drag it fully inside. Lambda, NAT and Aurora must sit **inside their subnet box**, because the lab decides a node's subnet from where its centre is.
- **A run shows a different result from the one above.** Send me a screenshot of the step list or the **Trace** panel and I'll adjust the file.

## About the lab files

The lab files use the same names, CIDRs and IAM permissions as `infra/cloudformation/exam-platform.yaml`.
