-- Fail closed on direct or inherited capabilities, including PUBLIC grants.
-- Never alter shared grants or unrelated workloads to make these checks pass.
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_roles WHERE rolname IN ('volta_reader','volta_auth','volta_readonly')) <> 3 THEN
    RAISE EXCEPTION 'Dedicated Volta roles are missing. Apply the owning role/bootstrap setup on a new cluster first.';
  END IF;
  IF EXISTS (SELECT FROM pg_roles WHERE rolname IN ('volta_reader','volta_auth','volta_readonly')
      AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls))
     OR EXISTS (SELECT FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.member
       WHERE r.rolname IN ('volta_reader','volta_auth','volta_readonly')
         AND NOT (r.rolname='volta_reader' AND m.roleid='volta_readonly'::regrole))
     OR EXISTS (SELECT FROM pg_roles r WHERE r.rolname IN ('volta_reader','volta_auth','volta_readonly')
       AND has_database_privilege(r.oid,current_database(),'CREATE'))
     OR EXISTS (SELECT FROM pg_namespace n CROSS JOIN pg_roles r
       WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
         AND r.rolname IN ('volta_reader','volta_auth','volta_readonly')
         AND has_schema_privilege(r.oid,n.oid,'CREATE'))
     OR EXISTS (SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN pg_roles r
       WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
         AND c.relkind IN ('r','p','v','m','f') AND r.rolname IN ('volta_reader','volta_auth','volta_readonly')
         AND NOT (r.rolname='volta_auth' AND n.nspname='volta')
         AND has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'))
     OR EXISTS (SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN pg_roles r
       WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
         AND c.relkind='S' AND r.rolname IN ('volta_reader','volta_auth','volta_readonly')
         AND NOT (r.rolname='volta_auth' AND n.nspname='volta')
         AND has_sequence_privilege(r.oid,c.oid,'USAGE,UPDATE'))
     OR EXISTS (SELECT FROM pg_roles r WHERE r.rolname IN ('volta_reader','volta_auth','volta_readonly')
       AND (has_schema_privilege(r.oid,'private','USAGE') OR has_table_privilege(r.oid,'private.tokens','SELECT'))) THEN
    RAISE EXCEPTION 'Dedicated Volta roles inherit unsafe privileges. Review existing PUBLIC/role grants with the TeslaMate administrator.';
  END IF;
END $$;
