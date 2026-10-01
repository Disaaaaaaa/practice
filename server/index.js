require('dotenv').config();
const path = require('path');
const express = require('express');
const cors = require('cors');
const { createClient } = require('@supabase/supabase-js');

const {
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
  OPENAI_API_KEY,
  OPENAI_MODEL = 'gpt-4o-mini',
  NICKNAME_DOMAIN = 'students.worksheet.local',
  DEFAULT_STUDENT_PASSWORD = '111111',
  PORT = 3000,
} = process.env;

// Supabase Auth requires an email address and (by default) a minimum
// password length of 6, so nicknames are mapped to a synthetic email and
// the temporary password is padded out. If you want the literal password
// "1", lower the minimum length in Supabase (Authentication > Policies)
// and set DEFAULT_STUDENT_PASSWORD=1 in server/.env.
function nicknameToEmail(nickname) {
  return `${String(nickname).trim().toLowerCase()}@${NICKNAME_DOMAIN}`;
}

// The original worksheet (public/index.html, #app). Kept as the default so
// every endpoint below still works for callers that don't pass an
// assignmentSlug — nothing about its existing behaviour changes.
const CURRENT_ASSIGNMENT_SLUG = 'web-page-design-theory';

const assignmentCache = new Map();
async function getAssignmentBySlug(slug) {
  if (assignmentCache.has(slug)) return assignmentCache.get(slug);
  const { data } = await supabaseAdmin.from('assignments').select('*').eq('slug', slug).single();
  if (data) assignmentCache.set(slug, data);
  return data || null;
}

// Every answer field that must be non-empty before each assignment can be
// submitted. Adding a new assignment (worksheet/mock exam) means: seed its
// mark_scheme rows (supabase/setup.sql), add its slug + required field ids
// here, and give it a rendering block in public/index.html.
const REQUIRED_FIELDS_BY_ASSIGNMENT = {
  'web-page-design-theory': [
    'q1', 'q2', 'q3a', 'q3b', 'q3c', 'q3d', 'q4a', 'q4b', 'q4c', 'q4d',
    'q5', 'q6', 'q7', 'q8', 'q9', 'q10', 'q11', 'q12', 'q13',
    'q14a', 'q14b', 'q14c', 'q15', 'q16',
  ],
  'paper-1-2023': [
    'p1_1a', 'p1_1b', 'p1_1c', 'p1_1d',
    'p1_2',
    'p1_3a', 'p1_3b',
    'p1_4a', 'p1_4b',
    'p1_5a', 'p1_5b', 'p1_5c', 'p1_5d',
    'p1_6a', 'p1_6b', 'p1_6c',
    'p1_7ai', 'p1_7aii', 'p1_7b', 'p1_7c',
    'p1_8a', 'p1_8bi', 'p1_8bii', 'p1_8biii',
    'p1_9',
    'p1_10ai', 'p1_10aii', 'p1_10bi', 'p1_10bii',
    'p1_11a', 'p1_11b', 'p1_11c', 'p1_11d',
    'p1_12a', 'p1_12b', 'p1_12c', 'p1_12d',
  ],
};

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.warn('[startup] SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set — auth-gated routes will fail. See server/.env.example.');
}
if (!OPENAI_API_KEY) {
  console.warn('[startup] OPENAI_API_KEY is not set — /api/ai-check will return 500. See server/.env.example.');
}

// Service-role client: full DB access, bypasses RLS. Only used server-side,
// and only after a request's bearer token has been verified below.
const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

async function requireUser(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'Missing bearer token' });
  const { data, error } = await supabaseAdmin.auth.getUser(token);
  if (error || !data.user) return res.status(401).json({ error: 'Invalid or expired session' });
  req.user = data.user;
  next();
}

async function getRole(userId) {
  const { data } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).single();
  return data?.role || 'student';
}

async function requireTeacher(req, res, next) {
  const role = await getRole(req.user.id);
  if (role !== 'teacher') return res.status(403).json({ error: 'Teacher account required.' });
  next();
}

app.get('/api/me', requireUser, async (req, res) => {
  const { data } = await supabaseAdmin
    .from('profiles')
    .select('id, nickname, full_name, role, must_change_password, class')
    .eq('id', req.user.id)
    .single();
  res.json({ profile: data || null });
});

// Gate before any worksheet is shown at all: returns every assignment the
// teacher has opened for this student's class. Checked server-side (not
// just hidden in the UI) because it's also enforced again in /api/submit.
// A student may see zero (locked screen), one (go straight in) or several
// (let them pick) open assignments.
app.get('/api/class-status', requireUser, async (req, res) => {
  const { data: prof } = await supabaseAdmin
    .from('profiles')
    .select('role, class')
    .eq('id', req.user.id)
    .single();

  if (!prof) return res.json({ open: false, class: null, assignments: [] });
  if (prof.role === 'teacher') return res.json({ open: true, class: null, assignments: [] });
  if (!prof.class) return res.json({ open: false, class: null, assignments: [] });

  const { data: assignments } = await supabaseAdmin.from('assignments').select('*').order('created_at');
  const { data: links } = await supabaseAdmin
    .from('class_assignments')
    .select('assignment_id, is_open')
    .eq('class_name', prof.class);

  const openAssignments = (assignments || [])
    .filter((a) => (links || []).some((l) => l.assignment_id === a.id && l.is_open))
    .map((a) => ({ slug: a.slug, title: a.title, type: a.type }));

  res.json({ open: openAssignments.length > 0, class: prof.class, assignments: openAssignments });
});

// Called by the client right after supabase.auth.updateUser({password}) succeeds,
// to clear the forced-change flag. Only touches the caller's own row.
app.post('/api/complete-password-change', requireUser, async (req, res) => {
  const { error } = await supabaseAdmin
    .from('profiles')
    .update({ must_change_password: false })
    .eq('id', req.user.id);
  if (error) return res.status(500).json({ error: error.message });
  res.json({ ok: true });
});

// ---------- teacher: account management (no public sign-up) ----------
const NICKNAME_RE = /^[a-z0-9._-]{3,32}$/;

app.post('/api/admin/create-user', requireUser, requireTeacher, async (req, res) => {
  const { nickname, role = 'student', fullName = null, className = null } = req.body || {};
  const cleanNickname = String(nickname || '').trim().toLowerCase();
  if (!NICKNAME_RE.test(cleanNickname)) {
    return res.status(400).json({ error: 'Nickname must be 3-32 characters: lowercase letters, numbers, dot, underscore or hyphen.' });
  }
  if (!['student', 'teacher'].includes(role)) {
    return res.status(400).json({ error: 'role must be student or teacher' });
  }
  if (role === 'student') {
    const { data: cls } = await supabaseAdmin.from('classes').select('name').eq('name', className).single();
    if (!cls) return res.status(400).json({ error: 'Pick a valid class for this student.' });
  }

  const { data, error } = await supabaseAdmin.auth.admin.createUser({
    email: nicknameToEmail(cleanNickname),
    password: DEFAULT_STUDENT_PASSWORD,
    email_confirm: true,
    user_metadata: { nickname: cleanNickname, full_name: fullName, role },
  });

  if (error) return res.status(400).json({ error: error.message });

  // Don't rely solely on the handle_new_user DB trigger (it may be an older
  // version, or run before this table had the nickname/must_change_password
  // columns) — set the profile row explicitly too.
  await supabaseAdmin.from('profiles').upsert(
    {
      id: data.user.id,
      nickname: cleanNickname,
      email: nicknameToEmail(cleanNickname),
      full_name: fullName,
      role,
      class: role === 'student' ? className : null,
      must_change_password: true,
    },
    { onConflict: 'id' }
  );

  res.json({ nickname: cleanNickname, tempPassword: DEFAULT_STUDENT_PASSWORD, userId: data.user.id });
});

// ---------- teacher: classes + per-class worksheet/mock-exam access ----------
app.get('/api/admin/classes', requireUser, requireTeacher, async (req, res) => {
  const { data, error } = await supabaseAdmin.from('classes').select('name').order('name');
  if (error) return res.status(500).json({ error: error.message });
  res.json({ classes: data });
});

// All assignments (worksheets/mock exams), with this class's open/closed
// status for each — merged, since a class with no class_assignments row
// yet for a given assignment should still show up as "Closed".
app.get('/api/admin/class-assignments', requireUser, requireTeacher, async (req, res) => {
  const { className } = req.query;
  if (!className) return res.status(400).json({ error: 'className is required' });

  const { data: assignments, error } = await supabaseAdmin.from('assignments').select('*').order('created_at');
  if (error) return res.status(500).json({ error: error.message });

  const { data: links } = await supabaseAdmin.from('class_assignments').select('*').eq('class_name', className);

  const merged = assignments.map((a) => {
    const link = (links || []).find((l) => l.assignment_id === a.id);
    return { ...a, is_open: !!link?.is_open, opened_at: link?.opened_at || null };
  });

  res.json({ assignments: merged });
});

app.post('/api/admin/class-assignments/toggle', requireUser, requireTeacher, async (req, res) => {
  const { className, assignmentId, open } = req.body || {};
  if (!className || !assignmentId) return res.status(400).json({ error: 'className and assignmentId are required' });

  const { error } = await supabaseAdmin.from('class_assignments').upsert(
    {
      class_name: className,
      assignment_id: assignmentId,
      is_open: !!open,
      opened_at: open ? new Date().toISOString() : null,
    },
    { onConflict: 'class_name,assignment_id' }
  );
  if (error) return res.status(500).json({ error: error.message });
  res.json({ ok: true });
});

app.post('/api/admin/reset-password', requireUser, requireTeacher, async (req, res) => {
  const { userId } = req.body || {};
  if (!userId) return res.status(400).json({ error: 'userId is required' });

  const { error: authError } = await supabaseAdmin.auth.admin.updateUserById(userId, {
    password: DEFAULT_STUDENT_PASSWORD,
  });
  if (authError) return res.status(400).json({ error: authError.message });

  const { error: dbError } = await supabaseAdmin
    .from('profiles')
    .update({ must_change_password: true })
    .eq('id', userId);
  if (dbError) return res.status(500).json({ error: dbError.message });

  res.json({ ok: true, tempPassword: DEFAULT_STUDENT_PASSWORD });
});

app.get('/api/admin/students', requireUser, requireTeacher, async (req, res) => {
  const { data, error } = await supabaseAdmin
    .from('profiles')
    .select('id, nickname, full_name, role, class, must_change_password, created_at')
    .order('created_at');
  if (error) return res.status(500).json({ error: error.message });
  res.json({ profiles: data });
});

// ---------- mark scheme: only released once this student's submission for THIS assignment is submitted ----------
app.get('/api/mark-scheme', requireUser, async (req, res) => {
  const slug = req.query.assignmentSlug || CURRENT_ASSIGNMENT_SLUG;
  const assignment = await getAssignmentBySlug(slug);
  if (!assignment) return res.status(404).json({ error: 'Unknown assignment' });

  const role = await getRole(req.user.id);
  let authorized = role === 'teacher';

  if (!authorized) {
    const { data: sub } = await supabaseAdmin
      .from('submissions')
      .select('submitted')
      .eq('student_id', req.user.id)
      .eq('assignment_id', assignment.id)
      .single();
    authorized = !!sub?.submitted;
  }

  if (!authorized) {
    return res.status(403).json({ error: 'Submit all your answers before the mark scheme is released.' });
  }

  const { data, error } = await supabaseAdmin
    .from('mark_scheme')
    .select('*')
    .eq('assignment_id', assignment.id)
    .order('id');
  if (error) return res.status(500).json({ error: error.message });
  res.json({ rows: data });
});

// ---------- submit: server validates completeness before flipping submitted=true ----------
app.post('/api/submit', requireUser, async (req, res) => {
  const { answers = {}, autoScore = null, selfScore = null, assignmentSlug = CURRENT_ASSIGNMENT_SLUG } = req.body || {};

  const assignment = await getAssignmentBySlug(assignmentSlug);
  if (!assignment) return res.status(404).json({ error: 'Unknown assignment' });

  const requiredFields = REQUIRED_FIELDS_BY_ASSIGNMENT[assignmentSlug] || [];
  const missing = requiredFields.filter((id) => !String(answers[id] ?? '').trim());
  if (missing.length) {
    return res.status(400).json({ error: 'Answer every question before submitting.', missing });
  }

  const { data: prof } = await supabaseAdmin.from('profiles').select('class').eq('id', req.user.id).single();
  if (prof?.class) {
    const { data: ca } = await supabaseAdmin
      .from('class_assignments')
      .select('is_open')
      .eq('class_name', prof.class)
      .eq('assignment_id', assignment.id)
      .single();
    if (!ca?.is_open) {
      return res.status(403).json({ error: 'Your teacher has not opened access for your class yet.' });
    }
  }

  const { data: existing } = await supabaseAdmin
    .from('submissions')
    .select('ai_feedback')
    .eq('student_id', req.user.id)
    .eq('assignment_id', assignment.id)
    .single();

  const { error } = await supabaseAdmin.from('submissions').upsert(
    {
      student_id: req.user.id,
      assignment_id: assignment.id,
      answers,
      auto_score: autoScore,
      self_score: selfScore,
      ai_feedback: existing?.ai_feedback || {},
      submitted: true,
      submitted_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'student_id,assignment_id' }
  );

  if (error) return res.status(500).json({ error: error.message });
  res.json({ ok: true });
});

// ---------- AI check: OpenAI key never leaves the server ----------
app.post('/api/ai-check', requireUser, async (req, res) => {
  const { questionId, answer, assignmentSlug = CURRENT_ASSIGNMENT_SLUG } = req.body || {};
  if (!questionId || typeof answer !== 'string') {
    return res.status(400).json({ error: 'questionId and answer are required' });
  }
  if (!answer.trim()) {
    return res.status(400).json({ error: 'Write an answer before requesting an AI check.' });
  }
  if (!OPENAI_API_KEY) {
    return res.status(500).json({ error: 'Server is missing OPENAI_API_KEY.' });
  }

  const assignment = await getAssignmentBySlug(assignmentSlug);
  if (!assignment) return res.status(404).json({ error: 'Unknown assignment' });

  const { data: scheme, error: schemeError } = await supabaseAdmin
    .from('mark_scheme')
    .select('*')
    .eq('id', questionId)
    .eq('assignment_id', assignment.id)
    .single();
  if (schemeError || !scheme) return res.status(404).json({ error: 'Unknown question id' });

  const system =
    'You are an experienced UK Computer Science exam marker (AQA A Level / NIS style). ' +
    "Mark the student's answer strictly against the official mark scheme points provided. " +
    'Award whole or half marks, never more than the maximum. ' +
    'Respond with ONLY compact JSON of the form {"marksAwarded": number, "feedback": "1-3 sentences, specific and constructive"}.';

  const user = [
    `Question: ${scheme.question}`,
    `Maximum marks: ${scheme.max_marks}`,
    'Mark scheme points:',
    ...(scheme.points || []).map((p) => `- ${p}`),
    scheme.model_answer ? `Model answer:\n${scheme.model_answer}` : null,
    'Student answer:',
    answer,
  ]
    .filter(Boolean)
    .join('\n');

  try {
    const resp = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        temperature: 0,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
      }),
    });

    if (!resp.ok) {
      const detail = await resp.text();
      return res.status(502).json({ error: 'OpenAI request failed', detail });
    }

    const json = await resp.json();
    let result;
    try {
      result = JSON.parse(json.choices[0].message.content);
    } catch {
      result = { marksAwarded: null, feedback: json.choices[0].message.content };
    }

    const { data: existing } = await supabaseAdmin
      .from('submissions')
      .select('ai_feedback')
      .eq('student_id', req.user.id)
      .eq('assignment_id', assignment.id)
      .single();
    const mergedFeedback = { ...(existing?.ai_feedback || {}), [questionId]: result };
    await supabaseAdmin
      .from('submissions')
      .upsert(
        { student_id: req.user.id, assignment_id: assignment.id, ai_feedback: mergedFeedback, updated_at: new Date().toISOString() },
        { onConflict: 'student_id,assignment_id' }
      );

    res.json({ maxMarks: scheme.max_marks, ...result });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/submission-status', requireUser, async (req, res) => {
  const slug = req.query.assignmentSlug || CURRENT_ASSIGNMENT_SLUG;
  const assignment = await getAssignmentBySlug(slug);
  if (!assignment) return res.status(404).json({ error: 'Unknown assignment' });

  const { data } = await supabaseAdmin
    .from('submissions')
    .select('answers, auto_score, self_score, ai_feedback, submitted, submitted_at')
    .eq('student_id', req.user.id)
    .eq('assignment_id', assignment.id)
    .single();
  res.json({ submission: data || null });
});

app.get('/api/health', (req, res) => {
  res.json({
    ok: true,
    supabaseConfigured: Boolean(SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY),
    openaiConfigured: Boolean(OPENAI_API_KEY),
  });
});

const publicDir = path.join(__dirname, '..', 'public');
app.use(express.static(publicDir));
app.get('/', (req, res) => res.sendFile(path.join(publicDir, 'index.html')));

// Only listen on a port for local dev (`npm start`). On Vercel this file is
// required by api/index.js and invoked per-request as a serverless
// function instead — it must not call app.listen() there.
if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`Worksheet server running at http://localhost:${PORT}`);
  });
}

module.exports = app;
