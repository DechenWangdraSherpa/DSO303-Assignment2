// Online Exams Portal - single page app (no framework, no build step).
const C = window.APP_CONFIG;
const $ = (id) => document.getElementById(id);
const AUTOSAVE_MS = 30_000;
let session = null, exam = null, autosaveTimer = null, clockTimer = null, dirty = false;

// ---------- auth: Cognito USER_PASSWORD_AUTH ----------
async function cognito(target, body) {
  const r = await fetch(C.cognitoEndpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/x-amz-json-1.1', 'x-amz-target': `AWSCognitoIdentityProviderService.${target}` },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j.message || j.__type || 'sign-in failed');
  return j;
}
const claims = (jwt) => JSON.parse(atob(jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));

async function login(username, password) {
  const r = await cognito('InitiateAuth', { AuthFlow: 'USER_PASSWORD_AUTH', ClientId: C.userPoolClientId, AuthParameters: { USERNAME: username, PASSWORD: password } });
  const idToken = r.AuthenticationResult.IdToken;
  const c = claims(idToken);
  let groups = c['cognito:groups'] || [];
  if (typeof groups === 'string') groups = groups.split(/[ ,]+/);
  session = { idToken, username: c['cognito:username'] || username, groups };
  sessionStorage.setItem('session', JSON.stringify(session));
  route();
}

async function api(method, path, body) {
  const r = await fetch(`${C.apiBase}/api${path}`, {
    method,
    headers: { authorization: `Bearer ${session.idToken}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(j.error || `HTTP ${r.status}`), { status: r.status });
  return j;
}

// ---------- views ----------
function show(view) {
  for (const v of ['login', 'student', 'exam', 'tutor']) $(`view-${v}`).hidden = v !== view;
}
function route() {
  if (!session) { $('who').textContent = ''; return show('login'); }
  const role = session.groups.includes('Admins') ? 'Administrator' : session.groups.includes('Tutors') ? 'Tutor' : 'Student';
  $('who').innerHTML = `${session.username} &middot; ${role} <button class="secondary" id="logout">Sign out</button>`;
  $('logout').onclick = () => { sessionStorage.clear(); session = null; stopExam(); route(); };
  if (role === 'Student') { show('student'); loadExams(); } else { show('tutor'); loadTutor(); }
}

// ---------- student ----------
async function loadExams() {
  const { exams } = await api('GET', '/exams');
  $('exam-list').innerHTML = exams.map((e) => `<li><span><strong>${e.title}</strong><br><span class="muted">${e.durationMinutes} minutes</span></span>
    <button data-exam="${e.examId}">Open exam</button></li>`).join('') || '<li>No exams scheduled.</li>';
  document.querySelectorAll('[data-exam]').forEach((b) => (b.onclick = () => openExam(b.dataset.exam)));
}

async function openExam(examId) {
  exam = await api('GET', `/exams/${examId}`);
  $('exam-title').textContent = exam.title;
  $('exam-meta').textContent = `${exam.questions.length} questions · ${exam.durationMinutes} minutes · answers autosave every 30 seconds`;
  const saved = exam.attempt.answers || {};
  $('exam-form').innerHTML = exam.questions.map((q, i) => `<div class="q"><p>${i + 1}. ${q.text} <span class="marks">(${q.marks} marks)</span></p>${
    q.type === 'mcq'
      ? q.options.map((o) => `<label class="opt"><input type="radio" name="${q.id}" value="${o}" ${saved[q.id] === o ? 'checked' : ''}>${o}</label>`).join('')
      : `<textarea name="${q.id}" rows="3">${saved[q.id] || ''}</textarea>`}</div>`).join('');
  $('exam-form').oninput = () => { dirty = true; };
  if (exam.attempt.savedAt) setSaveStatus(`Restored answers saved at ${new Date(exam.attempt.savedAt).toLocaleTimeString()}`, 'ok');
  if (exam.attempt.status !== 'IN_PROGRESS') { $('exam-status').textContent = `This attempt is ${exam.attempt.status.toLowerCase()}.`; }
  show('exam');
  const ends = new Date(exam.attempt.endsAt).getTime();
  clockTimer = setInterval(() => {
    const s = Math.max(0, Math.round((ends - Date.now()) / 1000));
    $('timer').textContent = `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
    if (s === 0) submitExam(true);
  }, 1000);
  autosaveTimer = setInterval(() => autosave(false), AUTOSAVE_MS);
}

function answers() {
  const out = {};
  for (const el of $('exam-form').elements) {
    if (el.type === 'radio' && el.checked) out[el.name] = el.value;
    if (el.tagName === 'TEXTAREA' && el.value) out[el.name] = el.value;
  }
  return out;
}
function setSaveStatus(t, cls) { const s = $('save-status'); s.textContent = t; s.className = `save-status ${cls || ''}`; }

async function autosave(manual) {
  if (!exam || (!dirty && !manual)) return;
  try {
    const r = await api('PUT', `/exams/${exam.examId}/autosave`, { answers: answers() });
    dirty = false;
    setSaveStatus(`Autosaved at ${new Date(r.savedAt).toLocaleTimeString()} (save #${r.saves})`, 'ok');
  } catch (e) {
    // Keep a local copy so nothing is lost if the network drops; retried on the next tick.
    try { localStorage.setItem(`draft-${exam.examId}`, JSON.stringify(answers())); } catch {}
    setSaveStatus(`Save failed (${e.message}) - will retry`, 'err');
  }
}

async function submitExam(auto) {
  if (!auto && !confirm('Submit your exam now? You cannot change answers afterwards.')) return;
  try {
    const r = await api('POST', `/exams/${exam.examId}/submit`, { answers: answers() });
    stopExam();
    $('exam-status').textContent = `Submitted at ${new Date(r.submittedAt).toLocaleTimeString()}. Multiple-choice marking is ${r.marking}.`;
    $('exam-status').className = 'status ok';
  } catch (e) { $('exam-status').textContent = e.message; $('exam-status').className = 'status err'; }
}
function stopExam() { clearInterval(autosaveTimer); clearInterval(clockTimer); }

async function upload() {
  const f = $('file').files[0];
  const st = $('upload-status');
  if (!f) { st.textContent = 'Choose a PDF or ZIP file first.'; return; }
  const contentType = f.name.toLowerCase().endsWith('.zip') ? 'application/zip' : 'application/pdf';
  st.className = 'status'; st.textContent = 'Requesting upload link...';
  try {
    const p = await api('POST', '/uploads', { courseId: 'DSO303', assignmentId: $('assignment').value, fileName: f.name, contentType, size: f.size });
    const form = new FormData();
    Object.entries(p.fields).forEach(([k, v]) => form.append(k, v));
    form.append('file', f);
    const bar = $('upload-progress'); bar.hidden = false; bar.value = 0;
    await new Promise((resolve, reject) => {
      const x = new XMLHttpRequest();
      x.open('POST', p.url);
      x.upload.onprogress = (e) => { if (e.lengthComputable) { bar.value = (e.loaded / e.total) * 100; st.textContent = `Uploading ${(e.loaded / 1048576).toFixed(1)} / ${(e.total / 1048576).toFixed(1)} MB`; } };
      x.onload = () => (x.status < 300 ? resolve() : reject(new Error(`storage rejected the file (HTTP ${x.status})`)));
      x.onerror = () => reject(new Error('network error'));
      x.send(form);
    });
    st.className = 'status ok';
    st.textContent = `Uploaded ${f.name} (${(f.size / 1048576).toFixed(1)} MB). Your tutor has been notified.`;
  } catch (e) { st.className = 'status err'; st.textContent = e.message; }
}

// ---------- tutor ----------
async function loadTutor() {
  const [{ submissions }, { results }] = await Promise.all([api('GET', '/submissions'), api('GET', '/exams/DSO303-MIDTERM/results')]);
  const t = (v) => (v ? new Date(v).toLocaleString() : '—');
  $('subs').innerHTML = submissions.map((s) => `<tr><td>${s.student_id}</td><td>${s.course_id} / ${s.assignment_id}</td><td>${(s.size_bytes / 1048576).toFixed(1)} MB</td><td>${t(s.received_at)}</td><td>${t(s.tutor_notified_at)}</td></tr>`).join('') || '<tr><td colspan="5">No submissions yet.</td></tr>';
  $('results').innerHTML = results.map((r) => `<tr><td>${r.student_id}</td><td>${r.score} / ${r.max_score}</td><td>${t(r.marked_at)}</td><td>${t(r.released_at)}</td></tr>`).join('') || '<tr><td colspan="4">Nothing marked yet.</td></tr>';
}
async function release() {
  try {
    const r = await api('POST', '/exams/DSO303-MIDTERM/release');
    $('release-status').className = 'status ok';
    $('release-status').textContent = `Released ${r.released} result(s); emails queued.`;
    loadTutor();
  } catch (e) { $('release-status').className = 'status err'; $('release-status').textContent = e.message; }
}

// ---------- wiring ----------
$('login-form').onsubmit = async (e) => {
  e.preventDefault(); $('login-error').textContent = '';
  try { await login($('username').value.trim(), $('password').value); } catch (err) { $('login-error').textContent = err.message; }
};
$('save-now').onclick = () => autosave(true);
$('submit-exam').onclick = () => submitExam(false);
$('upload-btn').onclick = upload;
$('refresh-subs').onclick = loadTutor;
$('release').onclick = release;
try { session = JSON.parse(sessionStorage.getItem('session')); } catch { session = null; }
route();
