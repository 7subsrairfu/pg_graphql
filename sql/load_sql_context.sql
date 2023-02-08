with search_path_oids(schema_oid) as (
    select y::regnamespace::oid from unnest(current_schemas(false)) x(y)
),
schemas_(oid, name) as (
    select
        pn.oid::int, pn.nspname::text
    from
        pg_namespace pn
        -- filter to current schemas only
        join search_path_oids cur_schemas(oid)
            on pn.oid = cur_schemas.oid
    where
        pg_catalog.has_schema_privilege(
            current_user,
            pn.oid,
            'USAGE'
        )
)
select
    jsonb_build_object(
        'config', jsonb_build_object(
            'search_path', (select array_agg(schema_oid) from search_path_oids),
            'role', current_role,
            'schema_version', graphql.get_schema_version()
        ),
        'enums', coalesce(
            (
                select
                    jsonb_object_agg(
                        distinct pt.oid::int,
                        jsonb_build_object(
                            'oid', pt.oid::int,
                            'schema_oid', pt.typnamespace::int,
                            'name', pt.typname,
                            'comment', pg_catalog.obj_description(pt.oid, 'pg_type'),
                            'directives', jsonb_build_object(
                                'name', graphql.comment_directive(pg_catalog.obj_description(pt.oid, 'pg_type')) ->> 'name'
                            ),
                            'values', (
                                select
                                    jsonb_agg(
                                        jsonb_build_object(
                                            'oid', pe.oid::int,
                                            'name', pe.enumlabel,
                                            'sort_order', (pe.enumsortorder * 100000)::int
                                        )
                                        order by pe.enumsortorder asc
                                    )
                                from
                                    pg_enum pe
                                where
                                    pt.oid = pe.enumtypid
                            ),
                            'permissions', jsonb_build_object(
                                'is_usable', pg_catalog.has_type_privilege(current_user, pt.oid, 'USAGE')
                            )
                        )
                    )
                from
                    pg_enum
                    join pg_type pt
                        on pt.oid = pg_enum.enumtypid
                    join schemas_ spo
                        on pt.typnamespace = spo.oid
            ),
            jsonb_build_object()
        ),
        'types', coalesce(
            (
                select
                    jsonb_object_agg(
                        pt.oid::int,
                        jsonb_build_object(
                            'oid', pt.oid::int,
                            'schema_oid', pt.typnamespace::int,
                            'name', pt.typname,
                            -- if type is an array, points at the underlying element type
                            'category', case
                                when pt.typcategory = 'A' then 'Array'
                                when pt.typcategory = 'E' then 'Enum'
                                when pt.typcategory = 'C' then 'Composite'
                                else 'Other'
                            end,
                            'array_element_type_oid', nullif(pt.typelem::int, 0),
                            'comment', pg_catalog.obj_description(pt.oid, 'pg_type'),
                            'directives', jsonb_build_object(
                                'name', graphql.comment_directive(pg_catalog.obj_description(pt.oid, 'pg_type')) ->> 'name'
                            ),
                            'permissions', jsonb_build_object(
                                'is_usable', pg_catalog.has_type_privilege(current_user, pt.oid, 'USAGE')
                            )
                        )
                    )
                from
                    pg_type pt
                    join schemas_ spo
                        on pt.typnamespace = spo.oid
            ),
            jsonb_build_object()
        ),
        'composites', coalesce(
            (
                select
                    jsonb_agg(
                        jsonb_build_object(
                            'oid', pt.oid::int,
                            'schema_oid', pt.typnamespace::int
                        )
                    )
                from
                    pg_type pt
                    join schemas_ spo
                        on pt.typnamespace = spo.oid
                where
                    pt.typtype = 'c'
            ),
            jsonb_build_array()
        ),
        'foreign_keys', (
            coalesce(
                (
                    select
                        jsonb_agg(
                            jsonb_build_object(
                                'local_table_meta', jsonb_build_object(
                                    'oid', pf.conrelid::int,
                                    'name', pa_local.relname::text,
                                    'schema', pa_local.relnamespace::regnamespace::text,
                                    'column_names', (
                                        select
                                            array_agg(pa.attname order by pfck.attnum_ix asc)
                                        from
                                            unnest(pf.conkey) with ordinality pfck(attnum, attnum_ix)
                                            join pg_attribute pa
                                                on pfck.attnum = pa.attnum
                                        where
                                            pa.attrelid = pf.conrelid
                                    )
                                ),
                                'referenced_table_meta', jsonb_build_object(
                                    'oid', pf.confrelid::int,
                                    'name', pa_referenced.relname::text,
                                    'schema', pa_referenced.relnamespace::regnamespace::text,
                                    'column_names', (
                                        select
                                            array_agg(pa.attname order by pfck.attnum_ix asc)
                                        from
                                            unnest(pf.confkey) with ordinality pfck(attnum, attnum_ix)
                                            join pg_attribute pa
                                                on pfck.attnum = pa.attnum
                                        where
                                            pa.attrelid = pf.confrelid
                                    )
                                ),
                                'directives', jsonb_build_object(
                                    'local_name', graphql.comment_directive(pg_catalog.obj_description(pf.oid, 'pg_constraint')) ->> 'local_name',
                                    'foreign_name', graphql.comment_directive(pg_catalog.obj_description(pf.oid, 'pg_constraint')) ->> 'foreign_name'
                                )
                            )
                        )
                    from
                        pg_catalog.pg_constraint pf
                        join pg_class pa_local
                            on pf.conrelid = pa_local.oid
                        join pg_class pa_referenced
                            on pf.confrelid = pa_referenced.oid
                        -- Referenced tables must also be on the search path
                        join search_path_oids spo
                            on pa_referenced.relnamespace = spo.schema_oid
                    where
                        pf.contype = 'f' -- foreign key
                ),
                jsonb_build_array()
            )
        ),
        'schemas', coalesce(
            (
                select
                    jsonb_object_agg(
                        pn.oid::int,
                        jsonb_build_object(
                            'oid', pn.oid::int,
                            'name', pn.name,
                            'comment', pg_catalog.obj_description(pn.oid, 'pg_namespace'),
                            'directives', jsonb_build_object(
                                'inflect_names', coalesce(
                                    (graphql.comment_directive(pg_catalog.obj_description(pn.oid, 'pg_namespace')) -> 'inflect_names') = to_jsonb(true),
                                    false
                                ),
                                'max_rows', coalesce(
                                    (graphql.comment_directive(pg_catalog.obj_description(pn.oid, 'pg_namespace')) ->> 'max_rows')::int,
                                    30
                                )
                            )
                        )
                    )
                from
                    schemas_ pn
            ),
            jsonb_build_object()
        ),
        'tables', coalesce(
            (
                select
                    jsonb_object_agg(
                        pc.oid::int,
                        jsonb_build_object(
                            'oid', pc.oid::int,
                            'name', pc.relname::text,
                            'relkind', pc.relkind::text,
                            'schema', schemas_.name,
                            'schema_oid', pc.relnamespace::int,
                            'comment', pg_catalog.obj_description(pc.oid, 'pg_class'),
                            'directives', jsonb_build_object(
                                'name', graphql.comment_directive(pg_catalog.obj_description(pc.oid, 'pg_class')) ->> 'name',
                                'total_count', jsonb_build_object(
                                    'enabled', coalesce(
                                        (
                                            graphql.comment_directive(
                                                pg_catalog.obj_description(pc.oid, 'pg_class')
                                            ) -> 'totalCount' ->> 'enabled' = 'true'
                                        ),
                                        false
                                    )
                                ),
                                'primary_key_columns', graphql.comment_directive(pg_catalog.obj_description(pc.oid, 'pg_class')) -> 'primary_key_columns',
                                'foreign_keys', graphql.comment_directive(pg_catalog.obj_description(pc.oid, 'pg_class')) -> 'foreign_keys'
                            ),
                            'functions', coalesce(
                                (
                                    select
                                        jsonb_agg(
                                            jsonb_build_object(
                                                'oid', pp.oid::int,
                                                'name', pp.proname::text,
                                                'type_oid', pp.prorettype::oid::int,
                                                'type_name', pp.prorettype::regtype::text,
                                                'schema_oid', pronamespace::int,
                                                'schema_name', pronamespace::regnamespace::text,
                                                'comment', pg_catalog.obj_description(pp.oid, 'pg_proc'),
                                                'directives', jsonb_build_object(
                                                    'name', graphql.comment_directive(pg_catalog.obj_description(pp.oid, 'pg_proc')) ->> 'name'
                                                ),
                                                'permissions', jsonb_build_object(
                                                    'is_executable', pg_catalog.has_function_privilege(
                                                        current_user,
                                                        pp.oid,
                                                        'EXECUTE'
                                                    )
                                                )
                                            )
                                        )
                                    from
                                        pg_catalog.pg_proc pp
                                    where
                                        pp.pronargs = 1 -- one argument
                                        and pp.proargtypes[0] = pc.reltype -- first argument is table type
                                        and pp.proname like '\_%' -- starts with underscore
                                ),
                                jsonb_build_array()
                            ),
                            'indexes', coalesce(
                                (
                                    select
                                        jsonb_agg(
                                            jsonb_build_object(
                                                'table_oid', pi.indrelid::int,
                                                'column_names', coalesce(
                                                    (
                                                        select
                                                            array_agg(pa_i.attname)
                                                        from
                                                            unnest(pi.indkey) pic(attnum)
                                                            join pg_catalog.pg_attribute pa_i
                                                                on pa_i.attrelid = pi.indrelid -- same table
                                                                and pic.attnum = pa_i.attnum -- same attribute
                                                    ),
                                                    array[]::text[]
                                                ),
                                                'is_unique', pi.indisunique,
                                                'is_primary_key', pi.indisprimary
                                            )
                                        )
                                    from
                                        pg_catalog.pg_index pi
                                    where
                                        pi.indrelid = pc.oid
                                ),
                                jsonb_build_array()
                            ),
                            'columns', (
                                select
                                    jsonb_agg(
                                        jsonb_build_object(
                                            'name', pa.attname::text,
                                            'type_oid', pa.atttypid::int,
                                            'type_name', pa.atttypid::regtype::text,
                                            'schema_oid', schemas_.oid::int,
                                            'is_not_null', pa.attnotnull,
                                            'attribute_num', pa.attnum,
                                            'has_default', pd.adbin is not null, -- pg_get_expr(pd.adbin, pd.adrelid) shows expression
                                            'is_serial', pg_get_serial_sequence(pc.oid::regclass::text, pa.attname::text) is not null,
                                            'is_generated', pa.attgenerated <> ''::"char",
                                            'permissions', jsonb_build_object(
                                                'is_insertable', pg_catalog.has_column_privilege(
                                                    current_user,
                                                    pa.attrelid,
                                                    pa.attname,
                                                    'INSERT'
                                                ),
                                                'is_selectable', pg_catalog.has_column_privilege(
                                                    current_user,
                                                    pa.attrelid,
                                                    pa.attname,
                                                    'SELECT'
                                                ),
                                                'is_updatable', pg_catalog.has_column_privilege(
                                                    current_user,
                                                    pa.attrelid,
                                                    pa.attname,
                                                    'UPDATE'
                                                )
                                            ),
                                            'comment', pg_catalog.col_description(pc.oid, pa.attnum),
                                            'directives', jsonb_build_object(
                                                'name', graphql.comment_directive(pg_catalog.col_description(pc.oid, pa.attnum)) ->> 'name'
                                            )
                                        )
                                        order by pa.attnum
                                    )
                                from
                                    pg_catalog.pg_attribute pa
                                    left join pg_catalog.pg_attrdef pd
                                        on (pa.attrelid, pa.attnum) = (pd.adrelid, pd.adnum)
                                where
                                    pc.oid = pa.attrelid
                                    and pa.attnum > 0
                                    and not pa.attisdropped
                            ),
                            'permissions', jsonb_build_object(
                                'is_insertable', pg_catalog.has_table_privilege(
                                    current_user,
                                    pc.oid,
                                    'INSERT'
                                ),
                                'is_selectable', pg_catalog.has_table_privilege(
                                    current_user,
                                    pc.oid,
                                    'SELECT'
                                ),
                                'is_updatable', pg_catalog.has_table_privilege(
                                    current_user,
                                    pc.oid,
                                    'UPDATE'
                                ),
                                'is_deletable', pg_catalog.has_table_privilege(
                                    current_user,
                                    pc.oid,
                                    'DELETE'
                                )
                            )
                        )
                    )
            from
                pg_class pc
                join schemas_
                    on pc.relnamespace = schemas_.oid
            where
                pc.relkind in (
                    'r', -- table
                    'v', -- view
                    'm', -- mat view
                    'f'  -- foreign table
                )
            ),
            jsonb_build_object()
        )

    )
