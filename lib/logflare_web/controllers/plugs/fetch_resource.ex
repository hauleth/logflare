defmodule LogflareWeb.Plugs.FetchResource do
  @moduledoc """
  Fetch the main relevant route resource based on conn.assigns.resource_type.

  Resource will be set on assigns with resource_type value as key

  For example with conn.assigns.resource_type: :source,
  conn.assigns.source will be fetched and set.

  The resource to be fetched should be set on the route's assigns option in the router.
  """
  import Plug.Conn
  alias Logflare.Sources
  alias Logflare.Endpoints
  def init(_opts), do: nil

  def call(%{assigns: %{resource_type: :source}, params: %{"source" => token}} = conn, _opts) do
    source = Sources.get_source_by_token(token)
    assign(conn, :source, source)
  end

  def call(
        %{
          assigns: %{resource_type: :endpoint} = assigns,
          params: %{"token_or_name" => token_or_name}
        } = conn,
        _opts
      ) do
    user_id =
      Map.get(assigns, :user)
      |> then(fn
        nil -> nil
        %_{} = user -> user.id
      end)

    endpoint =
      case is_uuid?(token_or_name) do
        true ->
          Endpoints.get_query_by_token(token_or_name)

        false when user_id != nil ->
          Endpoints.get_by(name: token_or_name, user_id: user_id)

        _ ->
          nil
      end

    assign(conn, :endpoint, endpoint)
  end

  def call(
        %{assigns: %{resource_type: :endpoint, user: %{id: user_id}}, params: %{"name" => name}} =
          conn,
        _opts
      ) do
    endpoint = Endpoints.get_by(name: name, user_id: user_id)
    assign(conn, :endpoint, endpoint)
  end

  def call(conn, _), do: conn

  # returns true if it is a valid uuid4 string
  defp is_uuid?(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
