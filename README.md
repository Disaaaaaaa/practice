# Web Page Design Theory Worksheet

A self-marking HTML worksheet with:

- **Nickname/password sign-in** via Supabase Auth — no public sign-up page; accounts are created by the teacher
- **AI checking** of written answers against the real mark scheme (OpenAI, called from a small Node server so the API key is never exposed to students)
- **No copy/paste** during the assessment (students only)
- **Tab-switch logging** — switching away is timestamped and visible to the teacher
- **Mark scheme release gating** — the mark scheme is stored in Postgres, not in the HTML, and is only served once a student's worksheet is marked `submitted` (checked server-side)
- **Teacher dashboard** — create student accounts, reset passwords, and review submissions, scores, and violation counts

## 1. Create the Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. Open the SQL editor and run the contents of [`supabase/setup.sql`](supabase/setup.sql). This creates `profiles`, `submissions`, `violations`, `mark_scheme`, the RLS policies, and seeds the mark scheme.
3. From **Project Settings → API**, copy:
   - `Project URL`
   - `anon` public key
   - `service_role` key (keep secret)

## 2. Configure the Node server

```bash
cd server
cp .env.example .env
```

Fill in `.env`:

```
SUPABASE_URL=...
SUPABASE_SERVICE_ROLE_KEY=...
OPENAI_API_KEY=...
NICKNAME_DOMAIN=students.worksheet.local
DEFAULT_STUDENT_PASSWORD=111111
```

`DEFAULT_STUDENT_PASSWORD` is the temporary password assigned to every new or reset account (Supabase requires 6+ characters by default, hence `111111` rather than `1`). Everyone is forced to set their own password on first login regardless.

Then install and run:

```bash
npm install
npm start
```

The server listens on `http://localhost:3000` and also serves the worksheet itself from `/public`.

## 3. Configure the worksheet's Supabase client

Open [`public/index.html`](public/index.html) and fill in near the top of the `<script type="module">` block:

```js
const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';
```

Also make sure the `NICKNAME_DOMAIN` constant a few lines below matches the one in `server/.env`.

The anon key is meant to be public (it only works within the RLS policies from `setup.sql`), so it's fine to leave it in the HTML. The service-role key and the OpenAI key must stay in `server/.env` only.

## 4. Create the first teacher account

There's no sign-up page, so bootstrap the first teacher from the command line:

```bash
cd server
node scripts/create-user.js --nickname=yourname --role=teacher --name="Your Name"
```

This prints a temporary password. Open `http://localhost:3000`, sign in with that nickname/password, and you'll immediately be asked to set your own password.

## 5. Use it

- **As the teacher**: open the **Teacher Dashboard** panel → "Create a student account" → enter a nickname (and optional full name) → it shows the generated temporary password. Give the nickname + password to that student. The dashboard also lists every student's submission status, auto/self/AI scores, and violation count, with a **Reset password** button per student.
- **As a student**: sign in with the nickname/password the teacher gave you → forced to set a new password on first login → answer every question → **Submit worksheet** (validated server-side — it refuses to submit until every question has an answer) → **Reveal mark scheme** unlocks.
- Any written answer has an **AI check** button that sends the question + the real mark scheme + the student's answer to OpenAI via the Node server and shows an estimated mark and feedback.
- Copying, cutting, pasting, and switching away from the tab are blocked/logged for students (not for the teacher) and show up in the Teacher Dashboard.

## Notes / things to decide as you go

- **Tab-switch policy**: currently it only warns and logs — it does not lock the worksheet. If you want a hard lock after N switches, that's a small change in the `onTabSwitch()` function in `public/index.html`.
- **Migrating from an older copy of this project**: if your database still has the old email/password sign-up schema, run the migration block near the bottom of `supabase/setup.sql` (adds `nickname`/`must_change_password`, drops the old self-update policy).

## Deploying to Vercel

The repo is already set up for it: `api/index.js` wraps the same Express app as a serverless function, and `vercel.json` routes `/api/*` there and everything else to `public/index.html`.

1. Import the GitHub repo into [vercel.com](https://vercel.com) (New Project → pick the repo). No build command needed — it's picked up as-is.
2. In **Project Settings → Environment Variables**, add the same values that are in `server/.env` locally:
   - `SUPABASE_URL`
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `OPENAI_API_KEY`
   - `NICKNAME_DOMAIN` (e.g. `students.worksheet.local`)
   - `DEFAULT_STUDENT_PASSWORD` (e.g. `111111`)
3. Deploy. Students use the Vercel URL instead of `localhost:3000`.
4. `server/scripts/create-user.js` (bootstrapping the teacher, and any CLI-based account creation) only works locally against `server/.env` — it doesn't run on Vercel. Either run it locally pointed at the same Supabase project, or use the Teacher Home page's UI once you have a teacher account.
5. The two local `.pdf` source files for Paper 1 2023 are gitignored (copyrighted NIS exam materials) and were never pushed — nothing to do there, the worksheet content itself already lives in `supabase/setup.sql`.
