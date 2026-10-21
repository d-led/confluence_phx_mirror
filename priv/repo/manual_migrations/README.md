Long-running, destructive and data migrations live here. They are applied only
by an operator with `ConfluencePhxMirror.Release.migrate_manual/0`, never on
boot. Create one with:

    mix ecto.gen.migration --migrations-path=priv/repo/manual_migrations some_name
