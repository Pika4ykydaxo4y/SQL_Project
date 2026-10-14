-- Creates two separate databases: OLTP and OLAP (DWH).
-- Run once as a superuser:  psql -U postgres -f 00_create_databases.sql
SELECT 'CREATE DATABASE steam_oltp_db' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'steam_oltp_db')\gexec
SELECT 'CREATE DATABASE steam_dwh_db'  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'steam_dwh_db')\gexec
