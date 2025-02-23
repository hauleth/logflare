defmodule Logflare.Backends.Adaptor.PostgresAdaptor.PgRepo do
  @moduledoc """
  Creates a Ecto.Repo for a source backend configuration, runs migrations and connects to it.

  Using the Source Backend source id we create a new Ecto.Repo which whom we will
  be able to connect to the configured PSQL URL, run migrations and insert data.
  """
  use GenServer

  alias Logflare.Backends.Adaptor.PostgresAdaptor
  alias Logflare.Backends.Adaptor.PostgresAdaptor.PgLogEvent
  alias Logflare.Backends.Adaptor.PostgresAdaptor.Repo.Migrations.AddLogEvents
  alias Logflare.Backends.Adaptor.PostgresAdaptor.PgRepoSupervisor
  alias Logflare.Backends.Adaptor.PostgresAdaptor.Supervisor
  alias Logflare.Backends.SourceBackend
  alias Logflare.LogEvent
  alias Logflare.Source
  require Logger

  @ast (quote do
          use Ecto.Repo,
            otp_app: :logflare,
            adapter: Ecto.Adapters.Postgres
        end)

  @doc """
  Dynamically compiles a new Ecto.Repo module for a given source.
  Requires `:source` to be preloaded.
  """
  @spec create_repo(SourceBackend.t()) :: atom()
  def create_repo(%SourceBackend{source: %Source{}, config: config} = source_backend) do
    name = get_repo_module(source_backend)

    unless Process.whereis(name) do
      child_spec = {__MODULE__, %{repo_module_name: name, config: config}}

      {:ok, _} = DynamicSupervisor.start_child(PgRepoSupervisor, child_spec)
    end

    name
  end

  @doc """
  Retrieves the repo module. Requires `:source` to be preloaded.
  """
  @spec get_repo_module(SourceBackend.t()) :: Ecto.Repo.t()
  def get_repo_module(%SourceBackend{config: config, source: %Source{}}) do
    data = inspect(config)
    sha256 = :crypto.hash(:sha256, data) |> Base.encode16() |> String.downcase()
    Module.concat([Logflare.Repo.Postgres, "Adaptor#{sha256}"])
  end

  @doc """
  Connects to a given postgres. Requires `:source` to be preloaded.
  """
  @spec connected?(SourceBackend.t()) :: :ok | {:error, :not_connected}
  def connected?(%SourceBackend{} = source_backend) do
    repo_module_name = get_repo_module(source_backend)
    connected?(repo_module_name, 5)
  end

  defp connected?(_repo_module_name, 0), do: {:error, :not_connected}
  defp connected?(_repo_module_name, :ok), do: :ok

  defp connected?(repo_module_name, acc) do
    case GenServer.call(via(repo_module_name), :connected?) do
      :ok ->
        connected?(repo_module_name, :ok)

      _ ->
        :timer.sleep(500)
        connected?(repo_module_name, acc - 1)
    end
  end

  @doc """
  Creates the Log Events table for the given source.
  """
  @spec create_log_events_table(SourceBackend.t(), list() | nil) ::
          :ok | {:error, :failed_migration}
  def create_log_events_table(source_backend, override_migrations \\ nil) do
    repo_module_name = get_repo_module(source_backend)
    migrations = if override_migrations, do: override_migrations, else: migrations(source_backend)
    schema = Map.get(source_backend.config, "schema") || Map.get(source_backend.config, :schema)
    opts = [all: true, prefix: schema, migrations: migrations]

    GenServer.call(via(repo_module_name), {:run_migrations, source_backend, opts})
  end

  @doc """
  Returns the table name for a given Source or SourceBackend.
  If SourceBackend, :source must be preloaded.
  """
  @spec table_name(SourceBackend.t() | Source.t()) :: binary()
  def table_name(%SourceBackend{source: %_{} = source}), do: table_name(source)

  def table_name(%Source{token: token}) do
    token
    |> Atom.to_string()
    |> String.replace("-", "_")
    |> then(&"log_events_#{&1}")
  end

  @doc """
  Retunrns a list of migrations to run.
  """
  @spec migrations(SourceBackend.t()) :: list({pos_integer(), atom()})
  def migrations(source_backend), do: [{1, AddLogEvents.generate_migration(source_backend)}]

  @doc """
  Rolls back all migrations
  """
  @spec rollback_migrations(SourceBackend.t()) :: :ok
  def rollback_migrations(source_backend) do
    repo_module_name = get_repo_module(source_backend)
    GenServer.call(via(repo_module_name), {:rollback_migrations_table, source_backend})
  end

  @doc """
  Drops the migration table
  """
  @spec drop_migrations_table(SourceBackend.t()) :: :ok
  def drop_migrations_table(source_backend) do
    repo_module_name = get_repo_module(source_backend)
    GenServer.call(via(repo_module_name), {:drop_migrations_table, source_backend})
  end

  @doc """
  Returns the migrations table name used for a given source
  """
  @spec migrations_table_name(SourceBackend.t()) :: String.t()
  def migrations_table_name(%SourceBackend{source: %Source{token: token}}) do
    token =
      token
      |> Atom.to_string()
      |> String.replace("-", "_")

    "schema_migrations_#{token}"
  end

  @doc """
  Inserts a LogEvent into the given source backend table
  """
  @spec insert_log_event(SourceBackend.t(), LogEvent.t()) :: {:ok, PgLogEvent.t()}
  def insert_log_event(source_backend, %LogEvent{} = log_event) do
    repo = get_repo_module(source_backend)
    table = PostgresAdaptor.table_name(source_backend)

    timestamp =
      log_event.body["timestamp"]
      |> DateTime.from_unix!(:microsecond)
      |> DateTime.to_naive()

    params = %{
      id: log_event.body["id"],
      event_message: log_event.body["event_message"],
      timestamp: timestamp,
      body: log_event.body
    }

    schema = Map.get(source_backend.config, "schema") || Map.get(source_backend.config, :schema)

    changeset =
      %PgLogEvent{}
      |> Ecto.put_meta(source: table, prefix: schema)
      |> PgLogEvent.changeset(params)

    repo.insert(changeset)
  end

  ## Genserver calls
  defp via(repo_module_name) do
    {:via, Registry, {Logflare.Backends.SourceRegistry, repo_module_name}}
  end

  def start_link(%{repo_module_name: repo_module_name} = state),
    do: GenServer.start_link(__MODULE__, state, name: via(repo_module_name))

  def init(state), do: {:ok, state, {:continue, :generate_repo_module}}

  def handle_continue(:generate_repo_module, %{repo_module_name: repo_module_name} = state) do
    case Code.ensure_compiled(repo_module_name) do
      {:module, _} -> nil
      _ -> {:module, _, _, _} = Module.create(repo_module_name, @ast, Macro.Env.location(__ENV__))
    end

    {:noreply, state, {:continue, :connect_repo}}
  end

  def handle_continue(:connect_repo, state) do
    %{config: config, repo_module_name: repo_module_name} = state

    pool_size =
      Keyword.get(Application.get_env(:logflare, :postgres_backend_adapter), :pool_size, 10)

    schema = Map.get(config, "schema") || Map.get(config, :schema)
    repo_opts = [url: config["url"] || config.url, name: repo_module_name, pool_size: pool_size]

    unless Process.whereis(repo_module_name) do
      {:ok, _} = DynamicSupervisor.start_child(Supervisor, repo_module_name.child_spec(repo_opts))

      if schema do
        query = """
        CREATE SCHEMA IF NOT EXISTS #{schema}
        """

        {:ok, _} = Ecto.Adapters.SQL.query(repo_module_name, query, [])
        Application.put_env(:logflare, repo_module_name, after_connect: after_connect(state))
      end
    end

    {:noreply, state}
  end

  def handle_call(:connected?, _, %{repo_module_name: repo_module_name} = state) do
    %Postgrex.Result{} = Ecto.Adapters.SQL.query!(repo_module_name, "SELECT 1")
    {:reply, :ok, state}
  rescue
    _ -> {:reply, :error, state}
  end

  def handle_call({:run_migrations, %SourceBackend{} = source_backend, opts}, _, state) do
    %{repo_module_name: repo_module_name} = state

    migrations_table_name = migrations_table_name(source_backend)
    {migrations, opts} = Keyword.pop!(opts, :migrations)

    Application.put_env(:logflare, repo_module_name,
      migration_source: migrations_table_name,
      after_connect: after_connect(state)
    )

    Ecto.Migrator.run(repo_module_name, migrations, :up, opts)

    {:reply, :ok, state}
  rescue
    e in Postgrex.Error ->
      Logger.error("Error creating log_events table: #{inspect(e)}")
      {:reply, {:error, :failed_migration}, state}
  end

  def handle_call({:drop_migrations_table, %SourceBackend{} = source_backend}, _, state) do
    %{repo_module_name: repo_module_name} = state
    migrations_table = migrations_table_name(source_backend)
    Ecto.Adapters.SQL.query!(repo_module_name, "DROP TABLE IF EXISTS #{migrations_table}")

    {:reply, :ok, state}
  rescue
    e in Postgrex.Error ->
      Logger.error("Error creating log_events table: #{inspect(e)}")
      {:reply, {:error, :failed_migration}, state}
  end

  def handle_call({:rollback_migrations_table, %SourceBackend{} = source_backend}, _, state) do
    repository_module = create_repo(source_backend)
    Ecto.Migrator.run(repository_module, migrations(source_backend), :down, all: true)

    {:reply, :ok, state}
  rescue
    e in Postgrex.Error ->
      Logger.error("Error creating log_events table: #{inspect(e)}")
      {:reply, {:error, :failed_migration}, state}
  end

  defp after_connect(%{config: %{schema: schema}}), do: after_connect(schema)
  defp after_connect(%{config: %{"schema" => schema}}), do: after_connect(schema)

  defp after_connect(schema) when is_binary(schema),
    do: {Postgrex, :query!, ["set search_path=#{schema}", []]}

  defp after_connect(_), do: nil
end
