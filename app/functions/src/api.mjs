// exam-api: the single Lambda behind the HTTP API. Small router, one handler per route.
import { GetCommand, PutCommand, UpdateCommand, QueryCommand } from '@aws-sdk/lib-dynamodb';
import { SendMessageCommand } from '@aws-sdk/client-sqs';
import { createPresignedPost } from '@aws-sdk/s3-presigned-post';
import { ddb, sqs, s3Presign, db, json, caller, log } from './lib.mjs';

const { EXAMS_TABLE, ATTEMPTS_TABLE, MARKING_QUEUE_URL, NOTIFY_QUEUE_URL, SUBMISSIONS_BUCKET } = process.env;
const MAX_UPLOAD = 50 * 1024 * 1024; // 50 MB
const ALLOWED = { 'application/pdf': 'pdf', 'application/zip': 'zip', 'application/x-zip-compressed': 'zip' };

export async function handler(event) {
  const method = event.requestContext?.http?.method || event.httpMethod;
  const path = (event.rawPath || event.path || '').replace(/\/+$/, '');
  if (method === 'OPTIONS') return { statusCode: 204 };
  if (path.endsWith('/health')) return json(200, { status: 'ok', az: process.env.AWS_AZ_HINT || 'regional', time: new Date().toISOString() });

  const user = await caller(event);
  if (!user) return json(401, { error: 'sign in required' });

  try {
    let m;
    if (method === 'GET' && path.endsWith('/exams')) return listExams(user);
    if ((m = path.match(/\/exams\/([^/]+)$/)) && method === 'GET') return openExam(user, m[1]);
    if ((m = path.match(/\/exams\/([^/]+)\/autosave$/)) && method === 'PUT') return autosave(user, m[1], body(event));
    if ((m = path.match(/\/exams\/([^/]+)\/submit$/)) && method === 'POST') return submit(user, m[1], body(event));
    if ((m = path.match(/\/exams\/([^/]+)\/release$/)) && method === 'POST') return releaseResults(user, m[1]);
    if ((m = path.match(/\/exams\/([^/]+)\/results$/)) && method === 'GET') return results(user, m[1]);
    if (path.endsWith('/uploads') && method === 'POST') return presignUpload(user, body(event));
    if (path.endsWith('/submissions') && method === 'GET') return submissions(user);
    return json(404, { error: `no route ${method} ${path}` });
  } catch (err) {
    console.error(err);
    return json(500, { error: 'internal error', detail: err.message });
  }
}

const body = (e) => {
  if (!e.body) return {};
  const raw = e.isBase64Encoded ? Buffer.from(e.body, 'base64').toString() : e.body;
  try { return JSON.parse(raw); } catch { return {}; }
};
const attemptKey = (user, examId) => ({ studentId: user.username, examId });

async function listExams(user) {
  // Small catalogue; a Query on a GSI would replace this at larger scale.
  const r = await ddb.send(new GetCommand({ TableName: EXAMS_TABLE, Key: { examId: 'CATALOGUE' } }));
  return json(200, { exams: r.Item?.exams || [], role: user.groups });
}

// Walkthrough 1, step 1: open the exam. Paper comes from DynamoDB (hot read path, no
// Aurora load at peak). The attempt row is created once; re-opening returns saved answers.
async function openExam(user, examId) {
  if (!user.is('Students')) return json(403, { error: 'students only' });
  const exam = (await ddb.send(new GetCommand({ TableName: EXAMS_TABLE, Key: { examId } }))).Item;
  if (!exam) return json(404, { error: 'exam not found' });
  const now = Date.now();
  const startedAt = new Date(now).toISOString();
  const endsAt = new Date(now + exam.durationMinutes * 60_000).toISOString();
  try {
    await ddb.send(new PutCommand({
      TableName: ATTEMPTS_TABLE,
      Item: { ...attemptKey(user, examId), status: 'IN_PROGRESS', startedAt, endsAt, answers: {}, saves: 0 },
      ConditionExpression: 'attribute_not_exists(studentId)',
    }));
  } catch (e) { if (e.name !== 'ConditionalCheckFailedException') throw e; }
  const attempt = (await ddb.send(new GetCommand({ TableName: ATTEMPTS_TABLE, Key: attemptKey(user, examId), ConsistentRead: true }))).Item;
  const questions = exam.questions.map(({ answer, ...q }) => q); // never send the answer key
  log('exam opened', { examId, student: user.username });
  return json(200, { examId, title: exam.title, durationMinutes: exam.durationMinutes, questions, attempt });
}

// Walkthrough 1, step 2: autosave every 30 s. One conditional write: only while the attempt
// is IN_PROGRESS and before the deadline (plus 60 s grace for network latency).
async function autosave(user, examId, { answers = {} }) {
  if (!user.is('Students')) return json(403, { error: 'students only' });
  const savedAt = new Date().toISOString();
  const graceEnd = new Date(Date.now() - 60_000).toISOString();
  try {
    const r = await ddb.send(new UpdateCommand({
      TableName: ATTEMPTS_TABLE,
      Key: attemptKey(user, examId),
      UpdateExpression: 'SET answers = :a, savedAt = :t ADD saves :one',
      ConditionExpression: '#s = :ip AND endsAt > :g',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: { ':a': answers, ':t': savedAt, ':one': 1, ':ip': 'IN_PROGRESS', ':g': graceEnd },
      ReturnValues: 'ALL_NEW',
    }));
    return json(200, { saved: true, savedAt, saves: r.Attributes.saves });
  } catch (e) {
    if (e.name === 'ConditionalCheckFailedException') return json(409, { error: 'attempt closed or time is up' });
    throw e;
  }
}

async function submit(user, examId, { answers }) {
  if (!user.is('Students')) return json(403, { error: 'students only' });
  const submittedAt = new Date().toISOString();
  const r = await ddb.send(new UpdateCommand({
    TableName: ATTEMPTS_TABLE,
    Key: attemptKey(user, examId),
    UpdateExpression: answers ? 'SET #s = :sub, submittedAt = :t, answers = :a' : 'SET #s = :sub, submittedAt = :t',
    ConditionExpression: '#s = :ip',
    ExpressionAttributeNames: { '#s': 'status' },
    ExpressionAttributeValues: { ':sub': 'SUBMITTED', ':t': submittedAt, ':ip': 'IN_PROGRESS', ...(answers ? { ':a': answers } : {}) },
  })).catch((e) => { if (e.name === 'ConditionalCheckFailedException') return null; throw e; });
  if (!r) return json(409, { error: 'already submitted' });
  // Marking is asynchronous: the student gets an instant response even at peak.
  await sqs.send(new SendMessageCommand({ QueueUrl: MARKING_QUEUE_URL, MessageBody: JSON.stringify({ examId, studentId: user.username, email: user.email }) }));
  return json(202, { submitted: true, submittedAt, marking: 'queued' });
}

async function releaseResults(user, examId) {
  if (!user.is('Tutors') && !user.is('Admins')) return json(403, { error: 'tutors only' });
  const pool = await db();
  const r = await pool.query('UPDATE results SET released_at = now() WHERE exam_id = $1 AND released_at IS NULL RETURNING student_id, student_email, score, max_score', [examId]);
  for (const row of r.rows) {
    await sqs.send(new SendMessageCommand({ QueueUrl: NOTIFY_QUEUE_URL, MessageBody: JSON.stringify({ type: 'RESULT_RELEASED', examId, to: row.student_email, studentId: row.student_id, score: row.score, maxScore: row.max_score }) }));
  }
  return json(200, { examId, released: r.rowCount });
}

async function results(user, examId) {
  const pool = await db();
  const isStaff = user.is('Tutors') || user.is('Admins');
  const r = isStaff
    ? await pool.query('SELECT student_id, score, max_score, marked_at, released_at FROM results WHERE exam_id=$1 ORDER BY student_id', [examId])
    : await pool.query('SELECT student_id, score, max_score, marked_at, released_at FROM results WHERE exam_id=$1 AND student_id=$2 AND released_at IS NOT NULL', [examId, user.username]);
  return json(200, { examId, results: r.rows });
}

// Walkthrough 2, step 1: hand the browser a presigned POST. The 40 MB file goes straight to
// S3; the policy enforces type and the 50 MB ceiling so the API never touches the bytes.
async function presignUpload(user, { courseId = 'DSO303', assignmentId = 'A2', fileName = 'assignment.pdf', contentType = 'application/pdf', size = 0 }) {
  if (!user.is('Students')) return json(403, { error: 'students only' });
  if (!ALLOWED[contentType]) return json(400, { error: 'only PDF or ZIP files are accepted' });
  if (size > MAX_UPLOAD) return json(400, { error: 'file exceeds 50 MB' });
  const safe = fileName.replace(/[^A-Za-z0-9._-]/g, '_');
  const key = `submissions/${courseId}/${assignmentId}/${user.username}/${Date.now()}-${safe}`;
  const post = await createPresignedPost(s3Presign, {
    Bucket: SUBMISSIONS_BUCKET,
    Key: key,
    Conditions: [['content-length-range', 1, MAX_UPLOAD], ['eq', '$Content-Type', contentType], ['eq', '$x-amz-server-side-encryption', 'aws:kms']],
    Fields: { 'Content-Type': contentType, 'x-amz-server-side-encryption': 'aws:kms', 'x-amz-meta-student': user.username, 'x-amz-meta-course': courseId, 'x-amz-meta-assignment': assignmentId },
    Expires: 900,
  });
  return json(200, { key, maxBytes: MAX_UPLOAD, expiresIn: 900, ...post });
}

async function submissions(user) {
  if (!user.is('Tutors') && !user.is('Admins')) return json(403, { error: 'tutors only' });
  const pool = await db();
  const r = await pool.query('SELECT id, course_id, assignment_id, student_id, s3_key, size_bytes, received_at, tutor_notified_at FROM submissions ORDER BY received_at DESC LIMIT 50');
  return json(200, { submissions: r.rows });
}
