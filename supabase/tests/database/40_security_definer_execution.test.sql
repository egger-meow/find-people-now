-- SECURITY DEFINER functions are never anonymous endpoints. Background jobs
-- and internal helpers must not be callable by authenticated users either.

begin;

create extension if not exists pgtap with schema extensions;
set search_path to public, extensions;

select plan(5);

select ok(
  not has_function_privilege('anon', 'public.commit_match(uuid, uuid)', 'execute'),
  'anon cannot execute the internal matching-engine entry point'
);

select ok(
  not has_function_privilege('authenticated', 'public.commit_match(uuid, uuid)', 'execute'),
  'authenticated cannot execute the internal matching-engine entry point'
);

select ok(
  not has_function_privilege('anon', 'public.fn_cleanup_pending_confirmations()', 'execute'),
  'anon cannot execute the pending-confirmation cleanup worker'
);

select ok(
  not has_function_privilege('authenticated', 'public.fn_cleanup_pending_confirmations()', 'execute'),
  'authenticated cannot execute the pending-confirmation cleanup worker'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.create_request(uuid, text, timestamp with time zone, timestamp with time zone, integer, integer, boolean, text, integer, text)',
    'execute'
  ),
  'authenticated can execute the current client create_request RPC'
);

select * from finish();

rollback;
