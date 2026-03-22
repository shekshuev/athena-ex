Postgrex.Types.define(
  Athena.PostgresTypes,
  [EctoLtree.Postgrex.Lquery, EctoLtree.Postgrex.Ltree] ++ Ecto.Adapters.Postgres.extensions()
)
