defmodule GenServerless.Backend do

  @timeout 60000

  @type event_type :: nil | :init | :cast | :stop

  @callback start_server(name :: String.t(), module :: module(), init_arg :: term()) ::
              :ok | {:error, reason :: term()}

  @callback stop_server(name :: String.t(), reason :: term()) :: :ok

  @callback acquire_state(name :: String.t(), type :: event_type(), data :: term(), timeout :: non_neg_integer()) ::
              {:ok, event_type :: event_type(), event_data :: term(), module :: module(), state :: term(), backend_info :: term()}
              | {:ok, :busy}
              | {:error, reason :: term()}

  @callback acquire_state(name :: String.t(), timeout :: non_neg_integer()) ::
              {:ok, event_type :: event_type(), event_data :: term(), module :: module(), state :: term(), backend_info :: term()}
              | {:ok, :empty | :busy}
              | {:error, reason :: term()}

  @callback release_state(name :: String.t(), state :: term(), backend_info :: term()) ::
              {:ok, needs_another :: boolean()}
              | {:error, reason :: term()}

  @callback post_cast(name :: String.t(), msg :: term()) :: :ok

  @callback post_stop(name :: String.t(), reason :: term()) :: :ok

  @callback post_ready(name :: String.t()) :: :ok

  require Logger

  def backend_module() do
    Application.get_env(:gen_serverless, :backend_module, GenServerless.LocalBackend)
  end

  def backend_apply(function, args) do
    Kernel.apply(backend_module(), function, args)
  end

  def make_ready_attrs(name) do
    %{"v" => "1", "e" => "ready", "n" => name}
  end

  def make_cast_attrs(name) do
    %{"v" => "1", "e" => "cast", "n" => name}
  end

  def make_stop_attrs(name) do
    %{"v" => "1", "e" => "stop", "n" => name}
  end

  def encode_body(attrs) do
    Jason.encode!(%{message: %{attributes: attrs}})
  end

  def encode_body(attrs, data) do
    Jason.encode!(%{message: %{attributes: attrs, data: data |> encode_term() |> Base.encode64()}})
  end

  def decode_term(str) do
    str |> Base.decode64!() |> :erlang.binary_to_term()
  end

  def encode_term(term) do
    term |> :erlang.term_to_binary() |> Base.encode64()
  end

  def handle_params(%{"message" => %{"attributes" => %{"v" => "1", "e" => "ready", "n" => name}}}) do
    Logger.debug("[Backend] handle_params: name=#{inspect(name)} type=ready")
    handle_event(name, [@timeout])
  end

  def handle_params(%{"message" => %{"attributes" => %{"v" => "1", "e" => type, "n" => name}, "data" => data}}) when type == "cast" or type == "stop" do
    type = String.to_atom(type)
    data = data |> Base.decode64!() |> decode_term()
    Logger.debug("[Backend] handle_params: name=#{inspect(name)} type=#{inspect(type)} data=#{inspect(data)}")
    handle_event(name, [type, data, @timeout])
  end

  def handle_params(params) do
    Logger.error("[Backend] Unrecognized params: #{inspect(params)}")
    {:error, :usage}
  end

  defp handle_event(name, acquire_args) do
    case backend_apply(:acquire_state, [name | acquire_args]) do
      {:ok, :init, init_arg, module, _state, backend_info} ->
        do_init(name, module, init_arg, backend_info)
      {:ok, :cast, msg, module, state, backend_info} ->
        do_cast(name, module, msg, state, backend_info)
      {:ok, :stop, reason, module, state, _backend_info} ->
        do_stop(name, module, reason, state)
      {:ok, result} ->
        Logger.debug("[Backend] handle_event: #{result}")
        :ok
      {:error, _reason} ->
        :ok
    end
  end

  defp do_init(name, module, init_arg, backend_info) do
    Logger.debug("[Backend] do_init: init_arg=#{inspect(init_arg)}")
    case apply(module, :init, [init_arg]) do
      {:ok, init_state} ->
        ready(name, init_state, backend_info)
      {:stop, reason} ->
        backend_apply(:stop_server, [name, reason])
        :ok
    end
  end

  defp do_stop(name, module, reason, state) do
    Logger.debug("[Backend] do_stop: reason=#{inspect(reason)} state=#{inspect(state)}")
    apply(module, :terminate, [reason, state])
    backend_apply(:stop_server, [name, reason])
    :ok
  end

  defp do_cast(name, module, msg, state, backend_info) do
    Logger.debug("[Backend] do_cast: msg=#{inspect(msg)} state=#{inspect(state)}")
    case apply(module, :handle_cast, [msg, state]) do
      {:noreply, new_state} ->
        ready(name, new_state, backend_info)
      {:stop, reason, new_state} ->
        do_stop(name, module, reason, new_state)
    end
  end

  defp ready(name, state, backend_info) do
    case backend_apply(:release_state, [name, state, backend_info]) do
      {:ok, true} ->
        backend_apply(:post_ready, [name])
        :ok
      {:ok, false} ->
        :ok
      {:error, _reason} ->
        :ok
    end
  end
end
