defmodule Plug.Parsers.NDJSON do
  @moduledoc """
  Parse Cloudflare Log Push request bodies.
  """
  require Logger

  @behaviour Plug.Parsers
  import Plug.Conn
  @gzip_header {"content-encoding", "gzip"}

  def init(_params) do
  end

  def parse(conn, "application", "x-ndjson", _headers, _opts) do
    conn
    |> read_body()
    |> decode()
  end

  @doc false
  def parse(conn, _type, _subtype, _headers, _opts) do
    {:next, conn}
  end

  def decode({:ok, <<>>, conn}) do
    {:ok, %{}, conn}
  end

  def decode({:ok, body, conn}) do
    body =
      if @gzip_header in conn.req_headers do
        body |> :zlib.gunzip() |> String.split("\n", trim: true)
      else
        body |> String.split("\n", trim: true)
      end

    batch =
      for line <- body do
        case Jason.decode(line) do
          {:ok, log_event} ->
            %{
              "timestamp" => log_event["EdgeStartTimestamp"],
              "event_message" => line,
              "metadata" => log_event
            }

          {:error, error} ->
            Logger.error("NDJSON parser error: " <> inspect(error))

            nil
        end
      end
      |> Enum.reject(&is_nil(&1))

    {:ok, %{"batch" => batch}, conn}
  rescue
    e ->
      reraise Plug.Parsers.ParseError, [exception: e], __STACKTRACE__
  end

  def decode({:more, _, conn}) do
    {:error, :too_large, conn}
  end

  def decode({:error, :timeout}) do
    raise Plug.TimeoutError
  end

  def decode({:error, _}) do
    raise Plug.BadRequestError
  end
end
