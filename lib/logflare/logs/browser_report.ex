defmodule Logflare.Logs.BrowserReport do
  @moduledoc false
  require Logger

  def handle_batch(batch) when is_list(batch) do
    Enum.map(batch, fn x -> handle_event(x) end)
  end

  def handle_event(params) when is_map(params) do
    %{
      "message" => message(params),
      "metadata" => params
    }
  end

  def message(params) do
    Jason.encode!(params)
  end
end
