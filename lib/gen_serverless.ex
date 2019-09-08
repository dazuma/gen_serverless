defmodule GenServerless do
  @moduledoc """
  Implementation of a GenServer-like construct atop serverless cloud

  Highly experimental. Not suitable for production.
  """

  alias GenServerless.Backend

  @callback init(arg :: term) ::
              {:ok, state :: term}
              | {:stop, reason :: term}

  @callback handle_cast(msg :: term, state :: term) ::
              {:noreply, new_state}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @callback terminate(reason :: term, state :: term) :: term

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour GenServerless

      @doc false
      def init(arg) do
        {:ok, arg}
      end

      @doc false
      def handle_cast(_msg, state) do
        {:noreply, state}
      end

      @doc false
      def terminate(_reason, _state) do
        :ok
      end

      defoverridable init: 1, handle_cast: 2, terminate: 2
    end
  end

  def start(module, init_arg, options \\ []) do
    name =
      case Keyword.pop(options, :name) do
        {nil, _opts} -> generate_name()
        {name, _opts} when is_atom(name) -> name
      end

    case Backend.backend_apply(:start_server, [name, module, init_arg]) do
      :ok ->
        Backend.backend_apply(:post_ready, [name])
        {:ok, name}

      error ->
        error
    end
  end

  def stop(name, reason \\ :normal) do
    Backend.backend_apply(:post_stop, [name, reason])
  end

  def cast(name, msg) do
    Backend.backend_apply(:post_cast, [name, msg])
    :ok
  end

  @rand_offset String.to_integer("ZZZZZZZZZZZZZZZ", 36)
  @rand_span String.to_integer("Z000000000000000", 36)

  defp generate_name() do
    Integer.to_string(:rand.uniform(@rand_span) + @rand_offset, 36)
  end
end
