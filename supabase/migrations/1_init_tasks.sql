-- Tasks table
create table public.tasks (
  task_id uuid default gen_random_uuid() primary key,
  user_id uuid references public.profiles on delete cascade,
  title text not null,
  description text,
  image_url text,
  label text check (label in ('work', 'personal', 'priority', 'shopping', 'home')),
  due_date timestamp with time zone,
  completed boolean default false,
  created_at timestamp with time zone default timezone('utc'::text, now()),
  updated_at timestamp with time zone default timezone('utc'::text, now())
);
