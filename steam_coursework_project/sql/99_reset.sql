-- Drops both databases. Use only to start from zero.  psql -U postgres -f 99_reset.sql
DROP DATABASE IF EXISTS steam_dwh_db;
DROP DATABASE IF EXISTS steam_oltp_db;
