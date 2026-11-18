// db-migrate: creates/updates the Aurora schema. Invoked by the deploy pipeline after every
// stack update. All statements are idempotent, so re-running it is always safe.
import { db, log } from './lib.mjs';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS tutors (
  id SERIAL PRIMARY KEY, course_id TEXT NOT NULL, name TEXT NOT NULL, email TEXT NOT NULL,
  UNIQUE (course_id, email));
CREATE TABLE IF NOT EXISTS exams (
  exam_id TEXT PRIMARY KEY, course_id TEXT NOT NULL, title TEXT NOT NULL,
  opens_at TIMESTAMPTZ, duration_minutes INT NOT NULL, created_by TEXT);
CREATE TABLE IF NOT EXISTS results (
  exam_id TEXT NOT NULL, student_id TEXT NOT NULL, student_email TEXT,
  score INT NOT NULL, max_score INT NOT NULL, short_answers_pending INT DEFAULT 0,
  marked_at TIMESTAMPTZ, released_at TIMESTAMPTZ, PRIMARY KEY (exam_id, student_id));
CREATE TABLE IF NOT EXISTS submissions (
  id SERIAL PRIMARY KEY, course_id TEXT, assignment_id TEXT, student_id TEXT,
  s3_key TEXT UNIQUE NOT NULL, size_bytes BIGINT, content_type TEXT, etag TEXT,
  received_at TIMESTAMPTZ DEFAULT now(), tutor_notified_at TIMESTAMPTZ);
INSERT INTO tutors (course_id, name, email) VALUES ('DSO303', 'Tutor One', 'tutor1@staff.example.edu')
  ON CONFLICT DO NOTHING;
INSERT INTO exams (exam_id, course_id, title, duration_minutes, created_by)
  VALUES ('DSO303-MIDTERM', 'DSO303', 'DSO303 Cloud Architecture Mid-term', 60, 'tutor1')
  ON CONFLICT DO NOTHING;
`;

export async function handler() {
  const pool = await db();
  await pool.query(SCHEMA);
  const t = await pool.query(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY 1`);
  const v = await pool.query('SELECT version()');
  const r = { tables: t.rows.map((x) => x.table_name), server: v.rows[0].version.split(',')[0] };
  log('migration complete', r);
  return r;
}
