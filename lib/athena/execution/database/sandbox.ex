defmodule Athena.Execution.Database.Sandbox do
  @moduledoc "Lifecycle shared by server database adapters. All submitted SQL runs as the temporary user."

  alias Athena.Execution.Database.{Limits, Statements}

  def execute(adapter, _box_id, setup, callback) do
    # Independent of caller/node-local box IDs, including overlapping instructor runs.
    token = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)

    credentials = %{
      database: "athena_#{token}",
      username: "u_#{token}",
      password: random_password()
    }

    case adapter.connect_admin() do
      {:ok, admin} -> execute_with_admin(adapter, admin, credentials, setup, callback)
      {:error, reason} -> {:error, {:system_error, reason}}
    end
  end

  defp execute_with_admin(adapter, admin, credentials, setup, callback) do
    with :ok <- adapter.provision(admin, credentials),
         {:ok, conn} <- adapter.connect_user(credentials) do
      execute_with_user(adapter, conn, setup, callback)
    else
      {:error, reason} -> {:error, {:system_error, reason}}
    end
  after
    adapter.cleanup(admin, credentials)
    GenServer.stop(admin)
  end

  defp execute_with_user(adapter, conn, setup, callback) do
    case execute_setup(adapter, conn, setup) do
      :ok -> {:ok, callback.(conn)}
      {:error, reason} -> {:error, {:setup_error, message(reason)}}
    end
  after
    GenServer.stop(conn)
  end

  defp execute_setup(_adapter, _conn, setup) when setup in [nil, ""], do: :ok

  defp execute_setup(adapter, conn, setup) do
    with {:ok, statements} <- Statements.split(setup, adapter.dialect()) do
      Enum.reduce_while(statements, :ok, &setup_statement(adapter, conn, &1, &2))
    end
  end

  defp setup_statement(adapter, conn, statement, :ok) do
    case adapter.query(conn, statement, 15.0) do
      {:ok, _} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  def stream_rows, do: Keyword.fetch!(Limits.config(), :stream_max_rows)

  def connection_options(module, default_port) do
    uri =
      module |> then(&Application.fetch_env!(:athena, &1)) |> Keyword.fetch!(:url) |> URI.parse()

    {user, password} =
      case String.split(uri.userinfo || "", ":", parts: 2) do
        [user, password] -> {user, password}
        [user] -> {user, ""}
      end

    [
      hostname: uri.host,
      port: uri.port || default_port,
      username: URI.decode(user),
      password: URI.decode(password),
      database: String.trim_leading(uri.path || "", "/"),
      pool_size: 1
    ]
  end

  defp random_password, do: :crypto.strong_rand_bytes(24) |> Base.encode16(case: :lower)
  defp message({_kind, message}) when is_binary(message), do: message
  defp message(reason), do: inspect(reason)
end
