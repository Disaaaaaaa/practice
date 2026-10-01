// One-off CLI to create a login (student or teacher) without the app's
// sign-up page, which doesn't exist by design. Mainly for bootstrapping the
// very first teacher account; after that, teachers create student accounts
// from the in-app dashboard.
//
// Usage (run from the server/ directory):
//   node scripts/create-user.js --nickname=aigerim.k --role=teacher
//   node scripts/create-user.js --nickname=student01 --role=student --password=1
//
// Requires server/.env to be filled in (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY).

require('dotenv').config();
const { createClient } = require('@supabase/supabase-js');

const {
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
  NICKNAME_DOMAIN = 'students.worksheet.local',
  DEFAULT_STUDENT_PASSWORD = '111111',
} = process.env;

function arg(name, fallback) {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
}

async function main() {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error('Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY — fill in server/.env first.');
    process.exit(1);
  }

  const nickname = arg('nickname');
  const role = arg('role', 'student');
  const password = arg('password', DEFAULT_STUDENT_PASSWORD);
  const fullName = arg('name', null);
  const className = arg('class', null);

  if (!nickname) {
    console.error('Usage: node scripts/create-user.js --nickname=<nickname> [--role=student|teacher] [--password=...] [--name="Full Name"]');
    process.exit(1);
  }
  if (!/^[a-z0-9._-]{3,32}$/.test(nickname)) {
    console.error('Nickname must be 3-32 chars: lowercase letters, numbers, dot, underscore or hyphen.');
    process.exit(1);
  }

  const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const email = `${nickname}@${NICKNAME_DOMAIN}`;

  const { data, error } = await supabaseAdmin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { nickname, full_name: fullName, role },
  });

  if (error) {
    console.error('Failed:', error.message);
    process.exit(1);
  }

  // Don't rely solely on the handle_new_user DB trigger — set the profile
  // row explicitly too, in case the trigger predates the nickname column.
  await supabaseAdmin.from('profiles').upsert(
    { id: data.user.id, nickname, email, full_name: fullName, role, class: role === 'student' ? className : null, must_change_password: true },
    { onConflict: 'id' }
  );

  console.log(`Created ${role}: nickname="${nickname}"  password="${password}"  (user id ${data.user.id})`);
  console.log('They will be asked to change this password on first login.');
}

main();
