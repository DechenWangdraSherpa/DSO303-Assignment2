// Asynchronous workers. Each is triggered by an SQS queue (with a dead-letter queue),
// so a burst of submissions or uploads is absorbed by the queue, not the database.
import { GetCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { SendMessageCommand } from '@aws-sdk/client-sqs';
import { HeadObjectCommand } from '@aws-sdk/client-s3';
import { SESv2Client, SendEmailCommand } from '@aws-sdk/client-sesv2';
import { ddb, sqs, s3, db, log } from './lib.mjs';

const { EXAMS_TABLE, ATTEMPTS_TABLE, NOTIFY_QUEUE_URL, MAIL_FROM } = process.env;
const ses = new SESv2Client({ region: process.env.AWS_REGION || 'us-east-1' });

// Report per-message failures so only the failed message is retried (ReportBatchItemFailures).
const each = (fn) => async (event) => {
  const batchItemFailures = [];
  for (const r of event.Records || []) {
    try { await fn(r); } catch (e) { console.error(e); batchItemFailures.push({ itemIdentifier: r.messageId }); }
  }
  return { batchItemFailures };
};

// ---------- marker: auto-marks MCQs, short answers go to the tutor ----------
export const marker = each(async (rec) => {
  const { examId, studentId, email } = JSON.parse(rec.body);
  const exam = (await ddb.send(new GetCommand({ TableName: EXAMS_TABLE, Key: { examId } }))).Item;
  const attempt = (await ddb.send(new GetCommand({ TableName: ATTEMPTS_TABLE, Key: { studentId, examId }, ConsistentRead: true }))).Item;
  let score = 0, max = 0, pendingShort = 0;
  for (const q of exam.questions) {
    if (q.type === 'mcq') { max += q.marks; if (attempt.answers?.[q.id] === q.answer) score += q.marks; }
    else pendingShort++;
  }
  const pool = await db();
  await pool.query(
    `INSERT INTO results (exam_id, student_id, student_email, score, max_score, short_answers_pending, marked_at)
     VALUES ($1,$2,$3,$4,$5,$6, now())
     ON CONFLICT (exam_id, student_id) DO UPDATE SET score=EXCLUDED.score, max_score=EXCLUDED.max_score, marked_at=now()`,
    [examId, studentId, email || `${studentId}@students.example.edu`, score, max, pendingShort]);
  await ddb.send(new UpdateCommand({ TableName: ATTEMPTS_TABLE, Key: { studentId, examId }, UpdateExpression: 'SET #s = :m, mcqScore = :sc', ExpressionAttributeNames: { '#s': 'status' }, ExpressionAttributeValues: { ':m': 'MARKED', ':sc': score } }));
  log('attempt marked', { examId, studentId, score, max, pendingShort });
});

// ---------- upload-processor: S3 ObjectCreated -> record + notify tutor ----------
export const uploadProcessor = each(async (rec) => {
  const evt = JSON.parse(rec.body);
  for (const r of evt.Records || []) {
    if (!r.eventName?.startsWith('ObjectCreated')) continue;
    const bucket = r.s3.bucket.name;
    const key = decodeURIComponent(r.s3.object.key.replace(/\+/g, ' '));
    const head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    const meta = head.Metadata || {};
    const [, course = meta.course, assignment = meta.assignment, student = meta.student] = key.split('/');
    const pool = await db();
    const t = await pool.query('SELECT email, name FROM tutors WHERE course_id = $1', [course]);
    const ins = await pool.query(
      `INSERT INTO submissions (course_id, assignment_id, student_id, s3_key, size_bytes, content_type, etag)
       VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (s3_key) DO NOTHING RETURNING id`,
      [course, assignment, student, key, head.ContentLength, head.ContentType, head.ETag]);
    if (!ins.rowCount) continue; // duplicate S3 event: already processed (idempotent)
    for (const tutor of t.rows) {
      await sqs.send(new SendMessageCommand({ QueueUrl: NOTIFY_QUEUE_URL, MessageBody: JSON.stringify({
        type: 'SUBMISSION_RECEIVED', submissionId: ins.rows[0].id, to: tutor.email, tutor: tutor.name,
        course, assignment, student, key, sizeBytes: head.ContentLength }) }));
    }
    log('submission recorded', { key, sizeBytes: head.ContentLength, tutors: t.rowCount });
  }
});

// ---------- notifier: the only component that sends email (SES) ----------
export const notifier = each(async (rec) => {
  const m = JSON.parse(rec.body);
  let subject, text;
  if (m.type === 'SUBMISSION_RECEIVED') {
    subject = `[${m.course}] New submission for ${m.assignment} from ${m.student}`;
    text = `Hello ${m.tutor},\n\n${m.student} submitted ${m.assignment} for ${m.course}.\nFile: ${m.key}\nSize: ${(m.sizeBytes / 1048576).toFixed(1)} MB\n\nOpen the tutor dashboard to download and mark it.`;
  } else if (m.type === 'RESULT_RELEASED') {
    subject = `Your result for ${m.examId} is available`;
    text = `Hello ${m.studentId},\n\nYour result for ${m.examId} has been released: ${m.score}/${m.maxScore} (MCQ section).\nSign in to view details.`;
  } else return;
  const out = await ses.send(new SendEmailCommand({
    FromEmailAddress: MAIL_FROM,
    Destination: { ToAddresses: [m.to] },
    Content: { Simple: { Subject: { Data: subject }, Body: { Text: { Data: text } } } },
  }));
  if (m.type === 'SUBMISSION_RECEIVED') {
    const pool = await db();
    await pool.query('UPDATE submissions SET tutor_notified_at = now() WHERE id = $1', [m.submissionId]);
  }
  log('email sent', { type: m.type, to: m.to, messageId: out.MessageId });
});
