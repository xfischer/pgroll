-- SPDX-License-Identifier: Apache-2.0
CREATE SCHEMA IF NOT EXISTS placeholder;

CREATE OR REPLACE FUNCTION placeholder.raw_migration ()
    RETURNS event_trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = placeholder, pg_catalog, pg_temp
    AS $$
DECLARE
    schemaname text;
    migration_id text;
BEGIN
    -- Ignore schema changes made by pgroll
    IF (pg_catalog.current_setting('pgroll.no_inferred_migrations', TRUE) = 'TRUE') THEN
        RETURN;
    END IF;
    IF tg_event = 'sql_drop' AND tg_tag = 'DROP SCHEMA' THEN
        -- Take the schema name from the drop schema command
        SELECT
            object_identity INTO schemaname
        FROM
            pg_event_trigger_dropped_objects ();
    ELSIF tg_event = 'sql_drop'
            AND tg_tag != 'ALTER TABLE' THEN
            -- Guess the schema from drop commands
            SELECT
                schema_name INTO schemaname
            FROM
                pg_catalog.pg_event_trigger_dropped_objects ()
            WHERE
                schema_name IS NOT NULL;
    ELSIF tg_event = 'ddl_command_end' THEN
        -- Guess the schema from ddl commands, ignore migrations that touch several schemas
        IF (
            SELECT
                pg_catalog.count(DISTINCT schema_name)
            FROM
                pg_catalog.pg_event_trigger_ddl_commands ()
            WHERE
                schema_name IS NOT NULL) > 1 THEN
            RETURN;
        END IF;
        IF tg_tag = 'CREATE SCHEMA' THEN
            SELECT
                object_identity INTO schemaname
            FROM
                pg_event_trigger_ddl_commands ();
        ELSE
            SELECT
                schema_name INTO schemaname
            FROM
                pg_catalog.pg_event_trigger_ddl_commands ()
            WHERE
                schema_name IS NOT NULL;
        END IF;
    END IF;
    IF schemaname IS NULL THEN
        RETURN;
    END IF;
    -- Ignore migrations done during a migration period
    IF placeholder.is_active_migration_period (schemaname) THEN
        RETURN;
    END IF;
    -- Remove any duplicate inferred migrations with the same timestamp for this
    -- schema. We assume such migrations are multi-statement batched migrations
    -- and we are only interested in the last one in the batch.
    DELETE FROM placeholder.migrations
    WHERE SCHEMA = schemaname
        AND created_at = CURRENT_TIMESTAMP
        AND migration_type = 'inferred'
        AND migration -> 'operations' -> 0 -> 'sql' ->> 'up' = current_query();
    -- Someone did a schema change without pgroll, include it in the history
    -- Get the latest non-inferred migration name with microsecond timestamp for ordering
    WITH latest_non_inferred AS (
        SELECT
            name
        FROM
            placeholder.migrations
        WHERE
            SCHEMA = schemaname
            AND migration_type != 'inferred'
        ORDER BY
            created_at DESC
        LIMIT 1
)
SELECT
    INTO migration_id CASE WHEN EXISTS (
        SELECT
            1
        FROM
            latest_non_inferred) THEN
        pg_catalog.format('%s_%s', (
                SELECT
                    name
                FROM latest_non_inferred), pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDDHH24MISSUS'))
    ELSE
        pg_catalog.format('00000_initial_%s', pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYYYMMDDHH24MISSUS'))
    END;
    INSERT INTO placeholder.migrations (schema, name, migration, resulting_schema, done, parent, migration_type, created_at, updated_at)
        VALUES (schemaname, migration_id, pg_catalog.json_build_object('version_schema', 'sql_' || substring(md5(random()::text), 1, 8), 'operations', (
                SELECT
                    pg_catalog.json_agg(pg_catalog.json_build_object('sql', pg_catalog.json_build_object('up', pg_catalog.current_query()))))),
            placeholder.read_schema (schemaname),
            TRUE,
            placeholder.latest_migration (schemaname),
            'inferred',
            statement_timestamp(),
            statement_timestamp());
END;
$$;

DROP EVENT TRIGGER IF EXISTS pg_roll_handle_ddl;

CREATE EVENT TRIGGER pg_roll_handle_ddl ON ddl_command_end
    EXECUTE FUNCTION placeholder.raw_migration ();

DROP EVENT TRIGGER IF EXISTS pg_roll_handle_drop;

CREATE EVENT TRIGGER pg_roll_handle_drop ON sql_drop
    EXECUTE FUNCTION placeholder.raw_migration ();

CREATE TABLE IF NOT EXISTS placeholder.migrations (
    schema NAME NOT NULL,
    name text NOT NULL,
    migration jsonb NOT NULL,
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    parent text,
    done boolean NOT NULL DEFAULT FALSE,
    resulting_schema jsonb NOT NULL DEFAULT '{}' ::jsonb,
    PRIMARY KEY (schema, name),
    FOREIGN KEY (schema, parent) REFERENCES placeholder.migrations (schema, name)
);

-- Only one migration can be active at a time
CREATE UNIQUE INDEX IF NOT EXISTS only_one_active ON placeholder.migrations (schema, name, done)
WHERE
    done = FALSE;

-- Only first migration can exist without parent
CREATE UNIQUE INDEX IF NOT EXISTS only_first_migration_without_parent ON placeholder.migrations (schema)
WHERE
    parent IS NULL;

-- History is linear
CREATE UNIQUE INDEX IF NOT EXISTS history_is_linear ON placeholder.migrations (schema, parent);

-- Add a column to tell whether the row represents an auto-detected DDL capture or a pgroll migration
ALTER TABLE placeholder.migrations
    ADD COLUMN IF NOT EXISTS migration_type varchar(32) DEFAULT 'pgroll' CONSTRAINT migration_type_check CHECK (migration_type IN ('pgroll', 'inferred'));

-- Update the `migration_type` column to also allow a `baseline` migration type.
ALTER TABLE placeholder.migrations
    DROP CONSTRAINT migration_type_check;

ALTER TABLE placeholder.migrations
    ADD CONSTRAINT migration_type_check CHECK (migration_type IN ('pgroll', 'inferred', 'baseline'));

-- Change timestamp columns to use timestamptz
ALTER TABLE placeholder.migrations
    ALTER COLUMN created_at SET DATA TYPE timestamptz USING created_at AT TIME ZONE 'UTC',
    ALTER COLUMN updated_at SET DATA TYPE timestamptz USING updated_at AT TIME ZONE 'UTC';

-- Table to track pgroll binary version
CREATE TABLE IF NOT EXISTS placeholder.pgroll_version (
    version text NOT NULL,
    initialized_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (version)
);

-- Helper functions
-- Are we in the middle of a migration?
CREATE OR REPLACE FUNCTION placeholder.is_active_migration_period (schemaname name)
    RETURNS boolean
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                placeholder.migrations
            WHERE
                SCHEMA = schemaname
                AND done = FALSE)
$$
LANGUAGE SQL
STABLE;

-- Get the name of the latest migration, or NULL if there is none.
-- This will be the same as the version-schema name of the migration in most
-- cases, unless the migration sets its `versionSchema` field.
CREATE OR REPLACE FUNCTION placeholder.latest_migration (schemaname name)
    RETURNS text
    SECURITY DEFINER
    SET search_path = placeholder, pg_catalog, pg_temp
    AS $$
    SELECT
        p.name
    FROM
        placeholder.migrations p
    WHERE
        NOT EXISTS (
            SELECT
                1
            FROM
                placeholder.migrations c
            WHERE
                SCHEMA = schemaname
                AND c.parent = p.name)
        AND SCHEMA = schemaname
$$
LANGUAGE SQL
STABLE;

-- Get the name of the previous migration, or NULL if there is none.
CREATE OR REPLACE FUNCTION placeholder.previous_migration (schemaname name)
    RETURNS text
    AS $$
    SELECT
        parent
    FROM
        placeholder.migrations
    WHERE
        SCHEMA = schemaname
        AND name = placeholder.latest_migration (schemaname);
$$
LANGUAGE SQL;

-- find_version_schema finds a recent version schema for a given schema name.
-- How recent is determined by the minDepth parameter: for a minDepth of 0, it
-- returns the latest version schema, for a minDepth of 1, it returns the
-- previous version schema, and so on.
-- Only version schemas that exist in the database are considered; migrations
-- without version schema (such as inferred migrations) are ignored.
CREATE OR REPLACE FUNCTION find_version_schema (p_schema_name name, p_depth integer DEFAULT 0)
    RETURNS text
    AS $$
    WITH RECURSIVE ancestors AS (
        SELECT
            name,
            COALESCE(migration ->> 'version_schema', name) AS version_schema,
            schema,
            parent,
            0 AS depth
        FROM
            placeholder.migrations
        WHERE
            name = placeholder.latest_migration (p_schema_name)
            AND SCHEMA = p_schema_name
        UNION ALL
        SELECT
            m.name,
            COALESCE(m.migration ->> 'version_schema', m.name) AS version_schema,
            m.schema,
            m.parent,
            a.depth + 1
        FROM
            placeholder.migrations m
            JOIN ancestors a ON m.name = a.parent
                AND m.schema = a.schema
)
        SELECT
            a.version_schema
        FROM
            ancestors a
    WHERE
        EXISTS (
            SELECT
                1
            FROM
                information_schema.schemata s
            WHERE
                s.schema_name = p_schema_name || '_' || a.version_schema)
    ORDER BY
        a.depth ASC OFFSET p_depth
    LIMIT 1;
$$
LANGUAGE SQL
STABLE;

-- previous_version returns the name of the previous version schema for a given
-- schema name or NULL if there is no previous version schema.
CREATE OR REPLACE FUNCTION previous_version (schemaname name)
    RETURNS text
    AS $$
    SELECT
        placeholder.find_version_schema (schemaname, 1);
$$
LANGUAGE SQL
STABLE;

-- latest_version returns the name of the latest version schema for a given
-- schema name or NULL if there are no version schema.
CREATE OR REPLACE FUNCTION latest_version (schemaname name)
    RETURNS text
    AS $$
    SELECT
        placeholder.find_version_schema (schemaname, 0);
$$
LANGUAGE SQL
STABLE;

-- Get the JSON representation of the current schema
CREATE OR REPLACE FUNCTION placeholder.read_schema (schemaname text)
    RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    tables jsonb;
BEGIN
    SELECT
        json_build_object('name', schemaname, 'tables', (
                SELECT
                    COALESCE(json_object_agg(t.relname, jsonb_strip_nulls (jsonb_build_object('name', t.relname, 'oid', t.oid, 'comment', descr.description, 'columns', (
                                        SELECT
                                            json_object_agg(name, c)
                                    FROM (
                                        SELECT
                                            attr.attname AS name, pg_get_expr(def.adbin, def.adrelid) AS default, NOT (attr.attnotnull
                                            OR tp.typtype = 'd'
                                            AND tp.typnotnull) AS nullable, CASE WHEN 'character varying'::regtype = ANY (ARRAY[attr.atttypid, tp.typelem]) THEN
                                        REPLACE(format_type(attr.atttypid, attr.atttypmod), 'character varying', 'varchar')
                                    WHEN 'timestamp with time zone'::regtype = ANY (ARRAY[attr.atttypid, tp.typelem]) THEN
                                        REPLACE(format_type(attr.atttypid, attr.atttypmod), 'timestamp with time zone', 'timestamptz')
                                    ELSE
                                        format_type(attr.atttypid, attr.atttypmod)
                                    END AS type, descr.description AS comment, (EXISTS (
                                            SELECT
                                                1
                                            FROM pg_constraint
                                            WHERE
                                                conrelid = attr.attrelid
                                                AND ARRAY[attr.attnum::int] @> conkey::int[]
                                                AND contype = 'u')
                                        OR EXISTS (
                                            SELECT
                                                1
                                            FROM pg_index
                                            JOIN pg_class ON pg_class.oid = pg_index.indexrelid
                                        WHERE
                                            indrelid = attr.attrelid
                                            AND indisunique
                                            AND ARRAY[attr.attnum::int] @> pg_index.indkey::int[])) AS unique, (
                                    SELECT
                                        array_agg(e.enumlabel ORDER BY e.enumsortorder)
                                    FROM pg_enum AS e
                                WHERE
                                    e.enumtypid = tp.oid) AS enumValues, CASE WHEN tp.typtype = 'b' THEN
                                    'base'
                                WHEN tp.typtype = 'c' THEN
                                    'composite'
                                WHEN tp.typtype = 'd' THEN
                                    'domain'
                                WHEN tp.typtype = 'e' THEN
                                    'enum'
                                WHEN tp.typtype = 'p' THEN
                                    'pseudo'
                                WHEN tp.typtype = 'r' THEN
                                    'range'
                                WHEN tp.typtype = 'm' THEN
                                    'multirange'
                                END AS postgresType FROM pg_attribute AS attr
                                INNER JOIN pg_type AS tp ON attr.atttypid = tp.oid
                                LEFT JOIN pg_attrdef AS def ON attr.attrelid = def.adrelid
                                    AND attr.attnum = def.adnum
                            LEFT JOIN pg_description AS descr ON attr.attrelid = descr.objoid
                                AND attr.attnum = descr.objsubid
                            WHERE
                                attr.attnum > 0
                                AND NOT attr.attisdropped
                                AND attr.attrelid = t.oid ORDER BY attr.attnum) c), 'primaryKey', (
                            SELECT
                                json_agg(pg_attribute.attname) AS primary_key_columns
                            FROM pg_index, pg_attribute
                            WHERE
                                indrelid = t.oid
                                AND nspname = schemaname
                                AND pg_attribute.attrelid = t.oid
                                AND pg_attribute.attnum = ANY (pg_index.indkey)
                                AND indisprimary), 'indexes', (
                                SELECT
                                    json_object_agg(ix_details.name, json_build_object('name', ix_details.name, 'unique', ix_details.indisunique, 'exclusion', ix_details.indisexclusion, 'columns', ix_details.columns, 'predicate', ix_details.predicate, 'method', ix_details.method, 'definition', ix_details.definition))
                            FROM (
                                SELECT
                                    replace(reverse(split_part(reverse(pi.indexrelid::regclass::text), '.', 1)), '"', '') AS name, pi.indisunique, pi.indisexclusion, array_agg(a.attname) AS columns, pg_get_expr(pi.indpred, t.oid) AS predicate, am.amname AS method, pg_get_indexdef(pi.indexrelid) AS definition
                                FROM pg_index pi
                                JOIN pg_attribute a ON a.attrelid = pi.indrelid
                                    AND a.attnum = ANY (pi.indkey)
                                JOIN pg_class cls ON cls.oid = pi.indexrelid
                                JOIN pg_am am ON am.oid = cls.relam
                                WHERE
                                    indrelid = t.oid::regclass GROUP BY pi.indexrelid, pi.indisunique, pi.indpred, am.amname) AS ix_details), 'checkConstraints', (
                        SELECT
                            json_object_agg(cc_details.conname, json_build_object('name', cc_details.conname, 'columns', cc_details.columns, 'definition', cc_details.definition, 'noInherit', cc_details.connoinherit))
                        FROM (
                            SELECT
                                cc_constraint.conname, array_agg(cc_attr.attname ORDER BY cc_constraint.conkey::int[]) AS columns, pg_get_constraintdef(cc_constraint.oid) AS definition, cc_constraint.connoinherit FROM pg_constraint AS cc_constraint
                            INNER JOIN pg_attribute cc_attr ON cc_attr.attrelid = cc_constraint.conrelid
                                AND cc_attr.attnum = ANY (cc_constraint.conkey)
                            WHERE
                                cc_constraint.conrelid = t.oid
                                AND cc_constraint.contype = 'c' GROUP BY cc_constraint.oid, cc_constraint.conname) AS cc_details), 'uniqueConstraints', (
                            SELECT
                                json_object_agg(uc_details.conname, json_build_object('name', uc_details.conname, 'columns', uc_details.columns))
                            FROM (
                                SELECT
                                    uc_constraint.conname, array_agg(uc_attr.attname ORDER BY uc_constraint.conkey::int[]) AS columns, pg_get_constraintdef(uc_constraint.oid) AS definition FROM pg_constraint AS uc_constraint
                                INNER JOIN pg_attribute uc_attr ON uc_attr.attrelid = uc_constraint.conrelid
                                    AND uc_attr.attnum = ANY (uc_constraint.conkey)
                                WHERE
                                    uc_constraint.conrelid = t.oid
                                    AND uc_constraint.contype = 'u' GROUP BY uc_constraint.oid, uc_constraint.conname) AS uc_details), 'excludeConstraints', (
                                SELECT
                                    json_object_agg(xc_details.conname, json_build_object('name', xc_details.conname, 'columns', xc_details.columns, 'definition', xc_details.definition, 'predicate', xc_details.predicate, 'method', xc_details.method))
                                FROM (
                                    SELECT
                                        xc_constraint.conname, array_agg(xc_attr.attname ORDER BY xc_constraint.conkey::int[]) AS columns, pg_get_expr(pi.indpred, t.oid) AS predicate, am.amname AS method, pg_get_constraintdef(xc_constraint.oid) AS definition FROM pg_constraint AS xc_constraint
                                    INNER JOIN pg_attribute xc_attr ON xc_attr.attrelid = xc_constraint.conrelid
                                        AND xc_attr.attnum = ANY (xc_constraint.conkey)
                                    JOIN pg_index pi ON pi.indexrelid = xc_constraint.conindid
                                    JOIN pg_class cls ON cls.oid = pi.indexrelid
                                    JOIN pg_am am ON am.oid = cls.relam
                                    WHERE
                                        xc_constraint.conrelid = t.oid
                                        AND xc_constraint.contype = 'x' GROUP BY xc_constraint.oid, xc_constraint.conname, pi.indpred, pi.indexrelid, am.amname) AS xc_details), 'foreignKeys', (
                                    SELECT
                                        json_object_agg(fk_details.conname, json_build_object('name', fk_details.conname, 'columns', fk_details.columns, 'referencedTable', fk_details.referencedTable, 'referencedColumns', fk_details.referencedColumns, 'matchType', fk_details.matchType, 'onDelete', fk_details.onDelete, 'onUpdate', fk_details.onUpdate))
                                    FROM (
                                        SELECT
                                            fk_info.conname AS conname, fk_info.columns AS columns, fk_info.relname AS referencedTable, array_agg(ref_attr.attname ORDER BY ref_attr.attname) AS referencedColumns, CASE WHEN fk_info.confmatchtype = 'f' THEN
                                            'FULL'
                                        WHEN fk_info.confmatchtype = 'p' THEN
                                            'PARTIAL'
                                        WHEN fk_info.confmatchtype = 's' THEN
                                            'SIMPLE'
                                        END AS matchType, CASE WHEN fk_info.confdeltype = 'a' THEN
                                            'NO ACTION'
                                        WHEN fk_info.confdeltype = 'r' THEN
                                            'RESTRICT'
                                        WHEN fk_info.confdeltype = 'c' THEN
                                            'CASCADE'
                                        WHEN fk_info.confdeltype = 'd' THEN
                                            'SET DEFAULT'
                                        WHEN fk_info.confdeltype = 'n' THEN
                                            'SET NULL'
                                        END AS onDelete, CASE WHEN fk_info.confupdtype = 'a' THEN
                                            'NO ACTION'
                                        WHEN fk_info.confupdtype = 'r' THEN
                                            'RESTRICT'
                                        WHEN fk_info.confupdtype = 'c' THEN
                                            'CASCADE'
                                        WHEN fk_info.confupdtype = 'd' THEN
                                            'SET DEFAULT'
                                        WHEN fk_info.confupdtype = 'n' THEN
                                            'SET NULL'
                                        END AS onUpdate FROM (
                                            SELECT
                                                fk_constraint.conname, fk_constraint.conrelid, fk_constraint.confrelid, fk_constraint.confkey, fk_cl.relname, fk_constraint.confmatchtype, fk_constraint.confdeltype, fk_constraint.confupdtype, array_agg(fk_attr.attname ORDER BY fk_attr.attname) AS columns FROM pg_constraint AS fk_constraint
                                            INNER JOIN pg_class fk_cl ON fk_constraint.confrelid = fk_cl.oid -- join the referenced table
                                            INNER JOIN pg_attribute fk_attr ON fk_attr.attrelid = fk_constraint.conrelid
                                                AND fk_attr.attnum = ANY (fk_constraint.conkey) -- join the columns of the referencing table
                                            WHERE
                                                fk_constraint.conrelid = t.oid
                                                AND fk_constraint.contype = 'f' GROUP BY fk_constraint.conrelid, fk_constraint.conname, fk_constraint.confrelid, fk_cl.relname, fk_constraint.confkey, fk_constraint.confmatchtype, fk_constraint.confdeltype, fk_constraint.confupdtype) AS fk_info
                                            INNER JOIN pg_attribute ref_attr ON ref_attr.attrelid = fk_info.confrelid
                                                AND ref_attr.attnum = ANY (fk_info.confkey) -- join the columns of the referenced table
                                        GROUP BY fk_info.conname, fk_info.conrelid, fk_info.columns, fk_info.confrelid, fk_info.confmatchtype, fk_info.confdeltype, fk_info.confupdtype, fk_info.relname) AS fk_details)))), '{}'::json)
                    FROM pg_class AS t
                    INNER JOIN pg_namespace AS ns ON t.relnamespace = ns.oid
                    LEFT JOIN pg_description AS descr ON t.oid = descr.objoid
                        AND descr.objsubid = 0
                    WHERE
                        ns.nspname = schemaname
                        AND t.relkind IN ('r', 'p') -- tables only (ignores views, materialized views & foreign tables)
)) INTO tables;
    RETURN tables;
END;
$$;

