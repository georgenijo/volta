-- Administrator applies these grants; volta_auth does not own the schema.
GRANT USAGE ON SCHEMA volta TO volta_auth;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA volta TO volta_auth;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA volta TO volta_auth;
