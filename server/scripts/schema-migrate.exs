Mix.install([{:ecto_sql, "~> 3.13"}, {:postgrex, "~> 0.21"}, {:cloak_ecto, "~> 1.3"}])
source = System.fetch_env!("TESLAMATE_SOURCE")
url = System.fetch_env!("SCHEMA_DATABASE_URL")
if URI.parse(url).path != "/volta_schema", do: raise("Schema generation requires its own volta_schema database")
defmodule TeslaMate.Repo do
  use Ecto.Repo, otp_app: :volta_schema, adapter: Ecto.Adapters.Postgres
end
Application.put_env(:volta_schema, TeslaMate.Repo, url: url, pool_size: 2)
{:ok, _} = TeslaMate.Repo.start_link()
Code.require_file(Path.join(source, "elixir/lib/teslamate/vault.ex"))
Code.require_file(Path.join(source, "elixir/lib/teslamate/settings/car_settings.ex"))
Ecto.Migrator.run(TeslaMate.Repo, Path.join(source, "elixir/priv/repo/migrations"), :up, all: true)
