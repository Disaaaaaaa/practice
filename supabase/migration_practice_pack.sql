-- Migration: add Binary Arithmetic practice pack as a real, gated assignment
-- (same model as Paper 1 2023). Idempotent.

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
