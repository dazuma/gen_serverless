defmodule GenServerless.LocalBackend do
  alias GenServerless.Backend
  alias GenServerless.LocalBackend.Impl

  def start_link(init_arg) do
    Impl.start_link(init_arg)
  end

  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]}
    }
  end

  require Logger

  @behaviour Backend

  @impl Backend
  def start_server(name, module, init_arg) do
    GenServer.call(Impl, {:start, name, module, init_arg})
  end

  @impl Backend
  def stop_server(name, reason) do
    GenServer.call(Impl, {:stop, name, reason})
  end

  @impl Backend
  def acquire_state(name, type, data, timeout) do
    GenServer.call(Impl, {:acquire_state, name, type, data, timeout})
  end

  @impl Backend
  def acquire_state(name, timeout) do
    GenServer.call(Impl, {:acquire_state, name, timeout})
  end

  @impl Backend
  def release_state(name, state, backend_info) do
    GenServer.call(Impl, {:release_state, name, state, backend_info})
  end

  @impl Backend
  def post_cast(name, msg) do
    Logger.debug("[LocalBackend] post_cast: name=#{inspect(name)} msg=#{inspect(msg)}")
    attrs = Backend.make_cast_attrs(name)
    Backend.encode_body(attrs, msg) |> post()
  end

  @impl Backend
  def post_stop(name, reason) do
    Logger.debug("[LocalBackend] post_stop: name=#{inspect(name)} reason=#{inspect(reason)}")
    attrs = Backend.make_stop_attrs(name)
    Backend.encode_body(attrs, reason) |> post()
  end

  @impl Backend
  def post_ready(name) do
    Logger.debug("[LocalBackend] post_ready: name=#{inspect(name)}")
    attrs = Backend.make_ready_attrs(name)
    Backend.encode_body(attrs) |> post()
  end

  defp post(body) do
    url = Application.get_env(:gen_serverless, :backend_url, "http://127.0.0.1:4000/genserverless")
    url = String.to_charlist(url)
    :httpc.request(:post, {url, [], 'application/json', body}, [],
                   [sync: false, receiver: fn(_) -> :ok end])
    :ok
  end

  defmodule ServerInfo do
    defstruct(
      module: nil,
      state: nil,
      queue: [],
      event: nil,
      deadline: nil
    )
  end

  defmodule Impl do
    alias GenServerless.LocalBackend.ServerInfo

    require Logger

    def start_link(init_arg) do
      GenServer.start(__MODULE__, init_arg, name: __MODULE__)
    end

    use GenServer

    def init(arg) do
      Logger.debug("[LocalBackend] init: arg=#{inspect(arg)}")
      {:ok, %{}}
    end

    def handle_call({:start, name, module, init_arg}, _from, servers) do
      Logger.debug("[LocalBackend] handle_call start: name=#{inspect(name)} module=#{inspect(module)} init_arg=#{inspect(init_arg)}")
      case Map.fetch(servers, name) do
        {:ok, _val} ->
          Logger.warn("  [LocalBackend] handle_call start: Name exists")
          {:reply, {:error, :exists}, servers}
        :error ->
          cur_time = System.monotonic_time(:millisecond)
          server_info = %ServerInfo{module: module, queue: [{:init, init_arg}], deadline: cur_time}
          servers = Map.put(servers, name, server_info)
          Logger.debug("  [LocalBackend] handle_call start: Added server")
          {:reply, :ok, servers}
      end
    end

    def handle_call({:stop, name, reason}, _from, servers) do
      Logger.debug("[LocalBackend] handle_call stop: name=#{inspect(name)} reason=#{inspect(reason)}")
      servers = Map.delete(servers, name)
      {:reply, :ok, servers}
    end

    def handle_call({:acquire_state, name, timeout}, _from, servers) do
      Logger.debug("[LocalBackend] handle_call acquire_event: name=#{inspect(name)}")
      cur_time = System.monotonic_time(:millisecond)
      case Map.fetch(servers, name) do
        {:ok, %ServerInfo{event: nil, queue: [{type, data} | queue]} = server_info} ->
          event_reply(servers, name, server_info, queue, type, data, cur_time + timeout)
        {:ok, %ServerInfo{event: nil}} ->
          Logger.debug("  [LocalBackend] handle_call acquire_event: empty")
          {:reply, {:ok, :empty}, servers}
        {:ok, %ServerInfo{}} ->
          Logger.debug("  [LocalBackend] handle_call acquire_event: busy")
          {:reply, {:ok, :busy}, servers}
        :error ->
          Logger.warn("  [LocalBackend] handle_call acquire_event: Name not found")
          {:reply, {:error, :notfound}, servers}
      end
    end

    def handle_call({:acquire_state, name, ntype, ndata, timeout}, _from, servers) do
      Logger.debug("[LocalBackend] handle_call acquire_state: name=#{inspect(name)} type=#{inspect(ntype)} data=#{inspect(ndata)}")
      cur_time = System.monotonic_time(:millisecond)
      case Map.fetch(servers, name) do
        {:ok, %ServerInfo{event: nil, queue: [{type, data} | queue]} = server_info} ->
          event_reply(servers, name, server_info, queue ++ [{ntype, ndata}], type, data, cur_time + timeout)
        {:ok, %ServerInfo{event: nil, queue: queue} = server_info} ->
          event_reply(servers, name, server_info, queue, ntype, ndata, cur_time + timeout)
        {:ok, %ServerInfo{queue: queue} = server_info} ->
          server_info = %ServerInfo{server_info | queue: queue ++ [{ntype, ndata}]}
          servers = Map.put(servers, name, server_info)
          Logger.debug("  [LocalBackend] handle_call acquire_event: queued")
          {:reply, {:ok, :busy}, servers}
        :error ->
          Logger.warn("  [LocalBackend] handle_call acquire_state: Name not found")
          {:reply, {:error, :notfound}, servers}
      end
    end

    def handle_call({:release_state, name, state, _backend_info}, _from, servers) do
      Logger.debug("[LocalBackend] handle_call release_state: name=#{inspect(name)} state=#{inspect(state)}")
      case Map.fetch(servers, name) do
        {:ok, %ServerInfo{event: event, queue: queue} = server_info} ->
          event_avail = !Enum.empty?(queue)
          if event == nil do
            Logger.warn("  [LocalBackend] handle_call release_state: Unexpectedly not handling event")
          else
            Logger.debug("  [LocalBackend] handle_call release_state: State released, event_avail=#{event_avail}")
          end
          server_info = %ServerInfo{server_info | state: state, event: nil}
          servers = Map.put(servers, name, server_info)
          {:reply, {:ok, event_avail}, servers}
        :error ->
          Logger.warn("  [LocalBackend] handle_call release_state: Name not found")
          {:reply, {:error, :notfound}, servers}
      end
    end

    defp event_reply(servers, name, %ServerInfo{module: module, state: state} = server_info, nqueue, type, data, deadline) do
      Logger.debug("  [LocalBackend] handle_call acquire_event: returning type=#{inspect(type)} data=#{inspect(data)} state=#{inspect(state)}")
      server_info = %ServerInfo{server_info | queue: nqueue, event: {type, data}, deadline: deadline}
      servers = Map.put(servers, name, server_info)
      {:reply, {:ok, type, data, module, state, nil}, servers}
    end
  end
end
