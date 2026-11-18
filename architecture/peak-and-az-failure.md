# Handling the exam peak and the loss of one Availability Zone

**The exam peak.** When 3,000 students start an exam within 5 minutes, about 10 students open the exam every second. Then about 100 autosaves arrive every second (3,000 students, one save every 30 seconds). The design handles this in five ways:

- CloudFront sends the website files from its own caches, so only API calls reach our servers.
- The API runs on AWS Lambda, which starts extra copies in seconds. Before each exam, 300 Lambda copies are switched on early, so the first students do not wait.
- Opening an exam and autosaving only use DynamoDB, which scales with the number of requests. The main database (Aurora) never sees this load.
- Submissions and uploads wait in SQS queues. If many arrive at once, marking simply finishes a little later.
- Files go straight from the browser to S3, so large uploads never slow down the API.

**Losing one Availability Zone.** An Availability Zone (AZ) is a separate data centre. Every part of the network is built twice, once in AZ-a and once in AZ-b. Each AZ has its own NAT gateway and its own Lambda subnet, and the database has a writer in AZ-a and a standby copy in AZ-b.

If AZ-a goes down, Lambda keeps running in AZ-b. Aurora promotes the AZ-b copy to be the new writer in about 30–60 seconds, and the API retries during that time. DynamoDB, S3, SQS, SES, Cognito, API Gateway and CloudFront already run across three AZs, so they keep working.

An autosave is only confirmed after DynamoDB has stored it in several AZs, so almost no answers can be lost. That is well inside the 5-minute limit. Backups can restore any point in time well within the 1-hour target.
