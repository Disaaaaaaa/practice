-- Web Page Design Theory Worksheet — Supabase schema
-- Run this once in the Supabase SQL editor for your project (Settings > SQL Editor).

create extension if not exists pgcrypto;

-- ---------- profiles ----------
-- There is no self-service sign-up. Accounts (student or teacher) are
-- created only by the Node server's admin endpoints / bootstrap script,
-- using the service-role key. Auth itself still uses Supabase's email+
-- password login — a "nickname" is mapped to a synthetic email address
-- (e.g. aigerim01@students.worksheet.local) by the server and the client;
-- students only ever see/type the nickname.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text unique,
  email text,
  full_name text,
  role text not null default 'student' check (role in ('student','teacher')),
  must_change_password boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- helper used by policies below (security definer avoids RLS recursion)
create or replace function public.is_teacher()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.profiles where id = auth.uid() and role = 'teacher'
  );
$$;

grant execute on function public.is_teacher() to authenticated;

drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select using (id = auth.uid() or public.is_teacher());

-- No insert/update policy for authenticated users: every write to profiles
-- (creating an account, resetting a password, clearing must_change_password)
-- goes through the Node server with the service-role key, which bypasses RLS.
-- This also means a student can never grant themselves the teacher role.
drop policy if exists "profiles_update_own" on public.profiles;

-- auto-create a profile row whenever an account is created via the
-- admin API (server). nickname/full_name/role come from the user_metadata
-- passed to supabaseAdmin.auth.admin.createUser().
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, nickname, email, full_name, role)
  values (
    new.id,
    new.raw_user_meta_data->>'nickname',
    new.email,
    new.raw_user_meta_data->>'full_name',
    coalesce(new.raw_user_meta_data->>'role', 'student')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- submissions ----------
create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references auth.users(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  auto_score int,
  self_score int,
  ai_feedback jsonb not null default '{}'::jsonb,
  submitted boolean not null default false,
  submitted_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.submissions enable row level security;

drop policy if exists "submissions_select" on public.submissions;
create policy "submissions_select" on public.submissions
  for select using (student_id = auth.uid() or public.is_teacher());

-- Students may insert/update their own row directly (used for autosave drafts),
-- but the `submitted` flag is only ever flipped to true by the Node server
-- (service-role key), which validates every question is answered first.
-- That's enforced in application code, not SQL, so keep this policy
-- permissive for the student's own row and rely on the server for the gate.
drop policy if exists "submissions_insert_own" on public.submissions;
create policy "submissions_insert_own" on public.submissions
  for insert with check (student_id = auth.uid());

drop policy if exists "submissions_update_own" on public.submissions;
create policy "submissions_update_own" on public.submissions
  for update using (student_id = auth.uid());

-- ---------- violations (tab-switch / copy-paste attempts) ----------
create table if not exists public.violations (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references auth.users(id) on delete cascade,
  type text not null check (type in ('tab_switch','copy_attempt','paste_attempt','cut_attempt')),
  occurred_at timestamptz not null default now(),
  meta jsonb not null default '{}'::jsonb
);

alter table public.violations enable row level security;

drop policy if exists "violations_select" on public.violations;
create policy "violations_select" on public.violations
  for select using (student_id = auth.uid() or public.is_teacher());

drop policy if exists "violations_insert_own" on public.violations;
create policy "violations_insert_own" on public.violations
  for insert with check (student_id = auth.uid());

-- ---------- mark_scheme (never shipped in the HTML) ----------
create table if not exists public.mark_scheme (
  id text primary key,
  question text not null,
  max_marks int not null,
  points jsonb not null default '[]'::jsonb,
  model_answer text
);

alter table public.mark_scheme enable row level security;

-- Defense-in-depth: even if something queried this table directly with the
-- anon key, a student can only read it once THEIR submission is submitted.
-- The Node server is the primary gate (it uses the service-role key and
-- re-checks this same condition before returning rows to the browser).
drop policy if exists "mark_scheme_select" on public.mark_scheme;
create policy "mark_scheme_select" on public.mark_scheme
  for select using (
    public.is_teacher()
    or exists (
      select 1 from public.submissions s
      where s.student_id = auth.uid() and s.submitted = true
    )
  );

-- ---------- seed the mark scheme ----------
insert into public.mark_scheme (id, question, max_marks, points, model_answer) values
('q1','State the main role of HTML and the main role of CSS.',2,
  '["HTML defines/structures page content. [1]","CSS controls presentation/styling/layout. [1]"]', null),
('q2','Explain why a <div> element is used in HTML.',2,
  '["Generic container used to group related elements. [1]","Allows them to be styled/positioned together or used as a layout container. [1]"]', null),
('q3','Select the most appropriate semantic HTML element for each purpose.',4,
  '["Major navigation links: nav [1]","Main unique page content: main [1]","Self-contained content item: article [1]","Footer information: footer [1]"]', null),
('q4','Select the correct CSS selector.',4,
  '["All paragraphs: p [1]","class=\"card\": .card [1]","id=\"header\": #header [1]","Links inside nav: nav a [1]"]', null),
('q5','Describe the four parts of the CSS box model.',4,
  '["Content: actual content area. [1]","Padding: space between content and border. [1]","Border: edge around content/padding. [1]","Margin: space outside the border. [1]"]', null),
('q6','Explain the difference between a class and an ID in HTML/CSS.',3,
  '["Class may be reused. [1]","ID identifies one unique element. [1]","Class uses `.`; ID uses `#`. [1]"]', null),
('q7','Explain why responsive design and media queries are used.',3,
  '["Adapts to different viewport/screen sizes. [1]","Media queries apply CSS when a condition is met. [1]","Improves usability/readability or prevents overflow. [1]"]', null),
('q8','A school website displays six course cards. Recommend Flexbox or CSS Grid and explain your answer.',4,
  '["Grid. [1]","Suitable for two-dimensional rows and columns. [1]","Provides consistent columns. [1]","gap provides consistent spacing / valid developed point. [1]"]', null),
('q9','Write a media query that changes .cards to one column when the viewport width is 700px or less.',3,
  '["Correct condition. [1]","Correct selector. [1]","Correct one-column rule. [1]"]',
  '@media (max-width: 700px) {
  .cards {
    grid-template-columns: 1fr;
  }
}'),
('q10','Identify suitable form controls for: full name, email, one study mode, several interests and a long personal statement. Justify one choice.',5,
  '["Full name: text input. [1]","Email: email input. [1]","Study mode: radio buttons. [1]","Interests: checkboxes. [1]","Personal statement: textarea / valid justification. [1]"]', null),
('q11','Explain one appropriate use of GET and one appropriate use of POST.',3,
  '["GET: suitable for search/filter request or query data in URL. [1]","POST: suitable for creating/changing data such as registration. [1]","POST sends form data in request body rather than address bar. [1]"]', null),
('q12','Explain why server-side validation is still required when client-side validation is used.',3,
  '["Client-side checks can be bypassed/disabled. [1]","Server must not trust incoming data. [1]","Server-side validation checks data again before processing/storage. [1]"]', null),
('q13','Explain two ways to improve the accessibility of an HTML form.',4,
  '["Award up to 2 marks per explained method: connected labels using for/id; fieldset/legend; visible focus; clear error messages; sufficient contrast; do not use placeholder as the only label."]', null),
('q14a','Explain the purpose of the outer <div class="cards">.',2,
  '["Groups the card elements. [1]","Acts as their Grid/layout container. [1]"]', null),
('q14b','Explain grid-template-columns: repeat(3, 1fr);.',2,
  '["Creates three columns. [1]","Of equal fractional width. [1]"]', null),
('q14c','Explain the effect of gap: 20px;.',2,
  '["Adds 20px spacing between grid items. [2]"]', null),
('q15','Rewrite the form using appropriate labels, IDs, names, input types and required validation.',5,
  '["Labels [1]","Matching for/id [1]","Names [1]","Email type [1]","Required validation / submit type [1]"]',
  '<form>
  <label for="name">Name</label>
  <input type="text" id="name" name="name" required>

  <label for="email">Email</label>
  <input type="email" id="email" name="email" required>

  <button type="submit">Send</button>
</form>'),
('q16','Write CSS for .form-card.',5,
  '["1 mark per correct declaration: max-width: 600px; padding: 20px; border: 1px solid #D8E0EB; border-radius: 12px; background: white;"]',
  '.form-card {
  max-width: 600px;
  padding: 20px;
  border: 1px solid #D8E0EB;
  border-radius: 12px;
  background: white;
}')
on conflict (id) do update set
  question = excluded.question,
  max_marks = excluded.max_marks,
  points = excluded.points,
  model_answer = excluded.model_answer;

-- ---------- classes ----------
-- A class must be opened by the teacher before its students can sign in and
-- see the worksheet at all (checked server-side in /api/class-status and
-- /api/submit, not just hidden in the UI).
create table if not exists public.classes (
  name text primary key,
  is_open boolean not null default false,
  opened_at timestamptz
);

alter table public.classes enable row level security;

-- Any signed-in user (student or teacher) can read class open/closed status —
-- needed for the gating check — but only the server (service-role key) ever
-- writes to this table, so there is no insert/update policy for students.
drop policy if exists "classes_select" on public.classes;
create policy "classes_select" on public.classes
  for select using (auth.uid() is not null);

insert into public.classes (name) values ('11/1'), ('11/3'), ('12')
on conflict (name) do nothing;

alter table public.profiles add column if not exists class text references public.classes(name);

-- ---------- assignments (worksheets / mock exams) ----------
-- A "class" by itself no longer carries open/closed state — access is now
-- per (class, assignment) pair via class_assignments, so the teacher can
-- open just one worksheet or mock exam for one class at a time. classes.is_open
-- above is kept only as a migration source for the row below and is no
-- longer read by the server.
create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  title text not null,
  type text not null default 'worksheet' check (type in ('worksheet','mock_exam')),
  created_at timestamptz not null default now()
);

alter table public.assignments enable row level security;
drop policy if exists "assignments_select" on public.assignments;
create policy "assignments_select" on public.assignments
  for select using (auth.uid() is not null);

create table if not exists public.class_assignments (
  class_name text not null references public.classes(name) on delete cascade,
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  is_open boolean not null default false,
  opened_at timestamptz,
  primary key (class_name, assignment_id)
);

alter table public.class_assignments enable row level security;
drop policy if exists "class_assignments_select" on public.class_assignments;
create policy "class_assignments_select" on public.class_assignments
  for select using (auth.uid() is not null);

-- the one worksheet this app currently serves
insert into public.assignments (slug, title, type) values
  ('web-page-design-theory', 'Web Page Design Theory Worksheet', 'worksheet')
on conflict (slug) do nothing;

-- give every class a row for it, carrying over whatever classes.is_open was
insert into public.class_assignments (class_name, assignment_id, is_open, opened_at)
select c.name, a.id, c.is_open, c.opened_at
from public.classes c
cross join public.assignments a
where a.slug = 'web-page-design-theory'
on conflict (class_name, assignment_id) do nothing;

-- ---------- adding another worksheet or mock exam later ----------
-- Insert a row here, then every class will show it (closed by default) in
-- its "Worksheets and Mock Exams" section:
--   insert into public.assignments (slug, title, type) values ('mock-exam-1', 'Mock Exam 1', 'mock_exam');

-- ---------- migrating an existing database ----------
-- If you ran an earlier version of this script, run the relevant lines once:
--   -- (nickname/password-reset support)
--   alter table public.profiles add column if not exists nickname text unique;
--   alter table public.profiles add column if not exists must_change_password boolean not null default true;
--   drop policy if exists "profiles_update_own" on public.profiles;
--   -- (classes support)
--   create table if not exists public.classes (name text primary key, is_open boolean not null default false, opened_at timestamptz);
--   alter table public.classes enable row level security;
--   create policy "classes_select" on public.classes for select using (auth.uid() is not null);
--   insert into public.classes (name) values ('11/1'), ('11/3'), ('12') on conflict (name) do nothing;
--   alter table public.profiles add column if not exists class text references public.classes(name);
--   -- (assignments / per-class worksheet access)
--   create table if not exists public.assignments (id uuid primary key default gen_random_uuid(), slug text unique not null, title text not null, type text not null default 'worksheet' check (type in ('worksheet','mock_exam')), created_at timestamptz not null default now());
--   alter table public.assignments enable row level security;
--   create policy "assignments_select" on public.assignments for select using (auth.uid() is not null);
--   create table if not exists public.class_assignments (class_name text not null references public.classes(name) on delete cascade, assignment_id uuid not null references public.assignments(id) on delete cascade, is_open boolean not null default false, opened_at timestamptz, primary key (class_name, assignment_id));
--   alter table public.class_assignments enable row level security;
--   create policy "class_assignments_select" on public.class_assignments for select using (auth.uid() is not null);
--   insert into public.assignments (slug, title, type) values ('web-page-design-theory', 'Web Page Design Theory Worksheet', 'worksheet') on conflict (slug) do nothing;
--   insert into public.class_assignments (class_name, assignment_id, is_open, opened_at) select c.name, a.id, c.is_open, c.opened_at from public.classes c cross join public.assignments a where a.slug = 'web-page-design-theory' on conflict (class_name, assignment_id) do nothing;
-- Then re-run the "create or replace function public.handle_new_user" block
-- above so new accounts also get a nickname.

-- ---------- creating accounts ----------
-- There is no sign-up page. Create the first teacher account from the
-- command line with server/scripts/create-user.js (see README.md), then
-- that teacher can create student accounts from the in-app Teacher Home
-- page, which calls the server's /api/admin/create-user endpoint.

-- ====================================================================
-- Everything below was added later, in supabase/migration_paper1.sql.
-- It's duplicated here too so a brand-new project only needs this one
-- file. If you already ran migration_paper1.sql separately, re-running
-- it (or this whole file) is safe — everything here is idempotent.
-- ====================================================================

-- Migration: multi-assignment submissions/mark_scheme + "Paper 1 2023" mock exam.
-- Run this once in the Supabase SQL editor. Idempotent (safe to re-run).

-- ---------- make submissions/mark_scheme assignment-aware ----------
-- Previously a student had exactly one submissions row total (unique on
-- student_id alone), which only worked because there was a single
-- assignment. Now there can be several, so submissions are keyed by
-- (student_id, assignment_id) instead.

alter table public.mark_scheme add column if not exists assignment_id uuid references public.assignments(id);

update public.mark_scheme
set assignment_id = (select id from public.assignments where slug = 'web-page-design-theory')
where assignment_id is null;

alter table public.mark_scheme alter column assignment_id set not null;

alter table public.submissions add column if not exists assignment_id uuid references public.assignments(id);

update public.submissions
set assignment_id = (select id from public.assignments where slug = 'web-page-design-theory')
where assignment_id is null;

alter table public.submissions alter column assignment_id set not null;

alter table public.submissions drop constraint if exists submissions_student_id_key;
alter table public.submissions drop constraint if exists submissions_student_id_assignment_id_key;
alter table public.submissions add constraint submissions_student_id_assignment_id_key unique (student_id, assignment_id);

-- Tighten the mark_scheme RLS policy now that there's more than one
-- assignment: a student submitting assignment A should not be able to read
-- assignment B's mark scheme just because *some* submission of theirs is
-- marked submitted. (The Node server was already scoping this correctly;
-- this closes the same gap at the RLS layer too.)
drop policy if exists "mark_scheme_select" on public.mark_scheme;
create policy "mark_scheme_select" on public.mark_scheme
  for select using (
    public.is_teacher()
    or exists (
      select 1 from public.submissions s
      where s.student_id = auth.uid()
        and s.assignment_id = mark_scheme.assignment_id
        and s.submitted = true
    )
  );

-- ---------- Paper 1 2023 (NIS Grade 12 Computer Science, May 2023, 70 marks) ----------
insert into public.assignments (slug, title, type) values
  ('paper-1-2023', 'Paper 1 2023', 'mock_exam')
on conflict (slug) do nothing;

insert into public.class_assignments (class_name, assignment_id, is_open)
select c.name, a.id, false
from public.classes c
cross join public.assignments a
where a.slug = 'paper-1-2023'
on conflict (class_name, assignment_id) do nothing;

insert into public.mark_scheme (id, assignment_id, question, max_marks, points, model_answer)
select v.id, a.id, v.question, v.max_marks, v.points::jsonb, v.model_answer
from (select id from public.assignments where slug = 'paper-1-2023') a,
(values
  ('p1_1a', 'Convert the binary integer 01011011 to denary.', 1,
    '["Denary: 91 (64+16+8+2+1). 1 mark for correct answer only."]', null::text),
  ('p1_1b', 'Convert the binary integer 01011011 to hexadecimal.', 1,
    '["Hexadecimal: 5B. 1 mark for correct answer only."]', null),
  ('p1_1c', 'Perform subtraction of the 8-bit binary number 00100111 from 01001001 using two''s complement. Show your working.', 3,
    '["Convert 00100111 to its two''s complement (negative) form: 11011001. [1 mark]","Add 01001001 + 11011001 = 100100010. [1 mark]","Subtraction result, dropping the overflow bit: 00100010 (accept 0100010). [1 mark]"]', null),
  ('p1_1d', 'Convert the denary number 17.75 into binary using normalised floating-point representation with 10 bits for the mantissa and 6 bits for the exponent, both expressed in two''s complement.', 4,
    '["17.75 in binary is 10001.11.","Normalised form is 0.1000111 x 2^5.","Mantissa (10 bits): 1000111000 — 1 mark for working out the mantissa.","Exponent (6-bit two''s complement) is 5: 000101 — 1 mark for the correct exponent.","1 further mark for correctly normalising the number; 1 further mark for overall correct final answer."]',
    '17.75 = 10001.11 (binary)
Normalised: 0.1000111 x 2^5
Mantissa (10 bits): 1000111000
Exponent (6-bit two''s complement): 000101'),
  ('p1_2', 'Explain the difference between data verification and validation.', 2,
    '["Validation: checking data is sensible/reasonable/clean and useful before it is accepted; checking the inputs to the system. [1 mark]","Verification: checking a copy of data is exactly equal to the original copy; carried out on copies/backups of data. [1 mark]","Any correctly explained difference between the two terms also earns both marks."]', null),
  ('p1_3a', 'Describe what blockchain technology is.', 1,
    '["A distributed database/ledger shared among the nodes of a computer network.","A growing list of records (blocks) linked together using cryptography.","A technology for maintaining a secure and decentralised record of transactions.","Accept any one reasonable description. Max 1 mark."]', null),
  ('p1_3b', 'Give one example of using blockchain technology.', 1,
    '["Cryptocurrencies/Bitcoin/Ethereum, smart contracts, financial services, games, supply chain, domain names — accept any correct example. Max 1 mark."]', null),
  ('p1_4a', 'Describe how encryption protects private information.', 1,
    '["The data is stored in a scrambled form.","Data is not understandable without the key.","Accept either point. Max 1 mark."]', null),
  ('p1_4b', 'List three other security measures to prevent hacking.', 3,
    '["Biometric authentication. [1]","Access control. [1]","Antivirus software. [1]","Firewall. [1]","Two-factor/double authentication. [1]","Strong passwords. [1]","Intranet. [1]","1 mark per correct measure, up to max 3. Do NOT accept ''Backup'' or ''Encryption'' as a security measure here."]', null),
  ('p1_5a', 'Describe two features of open-source software.', 2,
    '["Generally free to use. [1]","The source code is free to modify. [1]","Does not offer extensive support. [1]","Enables technology agility. [1]","1 mark per correct feature, up to max 2."]', null),
  ('p1_5b', 'Explain the risks of using cloud technologies.', 2,
    '["Anyone with illegal access to the cloud can steal/delete/change/corrupt data. [1]","Absence of internet connection or technical server problems causes unavailability of data. [1]","Cloud service quality may be inadequate. [1]","Providers cannot guarantee no service disruptions will occur; data may not be available 24/7. [1]","1 mark per correct risk, up to max 2."]', null),
  ('p1_5c', 'Write ways to protect against cracking.', 2,
    '["Enact two-factor authentication. [1]","Increase password complexity. [1]","Use SSL protocol. [1]","Encrypting data. [1]","Hashing. [1]","Attend to login attempts. [1]","1 mark per correct way, up to max 2. Do NOT accept ''Backup'', ''Firewall'' or ''Antivirus''."]', null),
  ('p1_5d', 'Explain legal ways to use images from the Internet.', 2,
    '["Use public domain images. [1]","Use stock photos. [1]","Use social media images only with permission. [1]","Buy original works from an author. [1]","1 mark per correct way, up to max 2. Do NOT accept an answer only about linking to the image."]', null),
  ('p1_6a', 'Three software types — General-purpose software, Bespoke software, Special-purpose software — each match one of these descriptions: (1) It can only be used for one particular task. (2) It is off-the-shelf software that can be used for a variety of tasks. (3) It is developed to meet the user''s specific requirements. State which description matches each software type.', 2,
    '["General-purpose software matches: off-the-shelf software that can be used for a variety of tasks.","Bespoke software matches: developed to meet the user''s specific requirements.","Special-purpose software matches: can only be used for one particular task.","Award 1 mark if only one pairing is correct; award 2 marks if all three pairings are correct; award 0 marks if a description is matched to more than one software type."]', null),
  ('p1_6b', 'Explain two functions of an operating system.', 2,
    '["Provides an interface for computer interaction. [1]","Management of hardware and peripherals. [1]","Processor management for multitasking. [1]","Management and loading of software. [1]","Management of user accounts. [1]","Control of inputs and outputs. [1]","Memory management. [1]","Interrupt handling. [1]","Error handling. [1]","Security. [1]","1 mark per correct function, up to max 2."]', null),
  ('p1_6c', 'Give two features of the batch operating system.', 2,
    '["Jobs with similar requirements are batched together and run through the computer as a group. [1]","Data is collected for a defined period of time and processed as a pack of similar tasks. [1]","Sorting is performed before processing. [1]","Does not require user interaction. [1]","1 mark per correct feature, up to max 2."]', null),
  ('p1_7ai', 'Describe the purpose of the Arithmetic Logic Unit (ALU).', 1,
    '["ALU processes and manipulates data.","ALU carries out arithmetic (+, -, *, /) and logic (AND, OR, NOT, etc.) operations.","Accept any reasonable answer. Max 1 mark."]', null),
  ('p1_7aii', 'Describe the purpose of the Control Unit (CU).', 1,
    '["CU manages the execution of instructions / directs the operation of the processor.","CU tells memory, the ALU and I/O devices how to respond to instructions sent to the processor.","CU fetches instructions from main memory into the instruction register and acts on its contents.","CU generates control signals that supervise the execution of instructions.","Accept any reasonable answer. Max 1 mark."]', null),
  ('p1_7b', 'Describe the purposes of the data bus, the address bus and the control bus.', 3,
    '["Data bus: transfers data between the processor and memory / between components on the motherboard. [1]","Address bus: specifies a physical memory address so the data bus can access it / identifies the cache or main memory location to read from or write to. [1]","Control bus: carries control commands between the processor and other components / transmits the clock''s pulses. [1]","1 mark per correct bus description."]', null),
  ('p1_7c', 'Explain what happens at each step of the fetch-decode-execute cycle.', 3,
    '["Fetch: the CPU fetches the instruction/data from main memory (RAM), using the program counter, into a register. [1]","Decode: the CPU decodes/organises the instruction into its significant parts; the instruction in the CIR is interpreted and the control unit works out what it is. [1]","Execute: the instruction is executed, using the ALU if necessary; data processing takes place. [1]"]', null),
  ('p1_8a', 'Explain the purpose of virtual memory.', 2,
    '["Frees up space in RAM.","Increases the amount of memory available by working outside the limits of physical main memory.","Allows multiple tasks to execute at once on one CPU.","Swapping uses virtual memory to copy contents between primary (RAM) and secondary memory.","Improves system performance when using large programs.","1 mark per correct point, up to max 2."]', null),
  ('p1_8bi', 'Describe the process of segmentation.', 2,
    '["The main memory is logically divided into variable-size parts (segments).","Each segment has its own base address.","A segment table stores the base address and length of each segment.","1 mark per correct point, up to max 2."]', null),
  ('p1_8bii', 'Define the term memory address.', 1,
    '["A reference to a specific/unique memory location used by software and hardware.","A unique identifier used by a device or CPU for data tracking.","The location of where a variable is stored in memory.","Accept any one. Max 1 mark."]', null),
  ('p1_8biii', 'The program below uses two types of addressing modes: Line 1: LDA #5. Line 2: ADD 6. (Lines 5-8 hold the data values 6, 2, 10, 15.) State the addressing mode used in line 1 and in line 2.', 2,
    '["Line 1: Immediate addressing. [1]","Line 2: Indexed addressing. [1]"]', null),
  ('p1_9', 'Write two differences between declarative and imperative programming.', 2,
    '["Declarative programming focuses on what the program should perform; imperative focuses on how it should achieve the result. [1]","In declarative programming execution is not clearly delineated; imperative programming is made up of a clearly defined sequence of instructions. [1]","Functional/Logic/Query programming are declarative; Procedural and Object-Oriented programming are imperative. [1]","1 mark per correct difference, up to max 2."]', null),
  ('p1_10ai', 'Describe two advantages of using a compiled programming language over an interpreted one.', 2,
    '["Does not need to compile every time the program is executed. [1]","Creates an executable/object file. [1]","The whole code translates faster. [1]","1 mark per correct advantage, up to max 2."]', null),
  ('p1_10aii', 'Describe two advantages of using an interpreted programming language instead of a compiled one.', 2,
    '["Relatively easy to debug / finds and displays errors as each instruction is run. [1]","Takes less memory for translation. [1]","Each line of code is translated to machine code and executed at the same time. [1]","1 mark per correct advantage, up to max 2."]', null),
  ('p1_10bi', 'A compiler translates source code through these stages: Source code -> [A] -> Syntax analysis -> ... -> Code generation -> [B] -> Object file. Name and describe stage A.', 2,
    '["Name: Lexical analysis. [1]","Description: the process of parsing a stream of individual characters/strings and converting it into a sequence of lexical tokens (lexemes); lexical errors occur when a sequence of characters does not match the pattern of any token. [1]"]', null),
  ('p1_10bii', 'In the same compiler pipeline, name and describe stage B.', 2,
    '["Name: Code optimization. [1]","Description: improves the code so it consumes fewer resources and runs faster/increases execution speed. [1]"]', null),
  ('p1_11a', 'Explain the purpose of the IP address.', 2,
    '["A unique address of a device on the network. [1]","Used to send and receive data. [1]","Used for the identification and location of a network device. [1]","1 mark per correct point, up to max 2."]', null),
  ('p1_11b', 'Given the four octet values A=131, B=29, C=109, D=191, write them in the correct order to form a valid IP address.', 1,
    '["Correct order is D.A.C.B -> 191.131.109.29. [1 mark]"]', '191.131.109.29'),
  ('p1_11c', 'Name the OSI layer that uses the IP address.', 1,
    '["Network layer. [1 mark]"]', null),
  ('p1_11d', 'IP address 10.21.129.46 (binary 00001010.00010101.10000001.00101110) and subnet mask 255.255.248.0 (binary 11111111.11111111.11111000.00000000) are given. Determine the network address in denary, showing your working.', 3,
    '["Bitwise AND of IP and mask: 00001010.00010101.10000000.00000000. [1 mark for the bitwise AND]","Convert each octet to decimal: 10.21.128.0. [1 mark for the decimal conversion]","Network address: 10.21.128.0 (accept 10.21.128). [1 mark for the correct network address]"]',
    '00001010.00010101.10000001.00101110
AND 11111111.11111111.11111000.00000000
= 00001010.00010101.10000000.00000000
= 10.21.128.0'),
  ('p1_12a', 'Explain how the Client-Server model works.', 2,
    '["The client makes a request to a server (e.g. the browser requests the DNS server after the user enters a URL). [1]","The server responds to the client''s request and sends the necessary files; the DNS server responds with the IP address of the web server. [1]","1 mark per correct point, up to max 2."]', null),
  ('p1_12b', 'Provide two situations when the Client-Server model may be unstable.', 2,
    '["The server is located at a great distance from the client. [1]","The server receives a large number of requests. [1]","If a centralised server is damaged, the data stored on it may be lost. [1]","1 mark per correct situation, up to max 2."]', null),
  ('p1_12c', 'Explain two differences between packet switching and circuit switching.', 2,
    '["Circuit switching only needs sender/recipient addresses when establishing the connection; packet switching needs a sender and recipient address on every packet. [1]","Circuit switching delivers data in order over one dedicated channel; packet switching does not need a dedicated channel and packets can take different routes. [1]","Per the official mark scheme: circuit switching may lose some packets, while packet switching ensures packets reach their destination. [1]","1 mark per correctly explained difference, up to max 2."]', null),
  ('p1_12d', 'State the second-level domain name of the website www.sk.nis.edu.kz.', 1,
    '["edu. [1 mark]"]', null)
) as v(id, question, max_marks, points, model_answer)
on conflict (id) do update set
  assignment_id = excluded.assignment_id,
  question = excluded.question,
  max_marks = excluded.max_marks,
  points = excluded.points,
  model_answer = excluded.model_answer;

-- ====================================================================
-- Added later, in supabase/migration_practice_pack.sql: the Binary
-- Arithmetic practice pack as a real, gated assignment (same model as
-- Paper 1 2023). Duplicated here too for a clean install from this file
-- alone.
-- ====================================================================

alter table public.assignments drop constraint if exists assignments_type_check;
alter table public.assignments add constraint assignments_type_check
  check (type in ('worksheet','mock_exam','practice'));

insert into public.assignments (slug, title, type) values
  ('binary-arithmetic-practice', 'Binary Arithmetic & Two''s Complement — Practice Pack', 'practice')
on conflict (slug) do nothing;

insert into public.class_assignments (class_name, assignment_id, is_open)
select c.name, a.id, false
from public.classes c
cross join public.assignments a
where a.slug = 'binary-arithmetic-practice'
on conflict (class_name, assignment_id) do nothing;
